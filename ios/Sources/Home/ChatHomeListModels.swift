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

    // Prefer the raw avatar when it's already a direct HTTPS URL — it carries its
    // own cache key so a changed image URL automatically busts the in-app cache.
    if let trimmed = normalizedString(rawAvatar), isHTTPURL(trimmed) {
      return trimmed
    }

    if preferPushAvatar,
      let normalizedPeerUserId = normalizedString(peerUserId),
      let apiBaseURL
    {
      return pushAvatarURL(baseURL: apiBaseURL, userId: normalizedPeerUserId)
    }

    guard let trimmed = normalizedString(rawAvatar) else { return nil }
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
    cache.countLimit = 128
    // ~24 MB of decoded avatar pixels (cost ≈ width*height*4 when known).
    cache.totalCostLimit = 24 * 1024 * 1024
    return cache
  }()
  private static let inFlightCoordinator = ChatAvatarImageLoadCoordinator()

  static func cached(for rawValue: String?) -> UIImage? {
    guard let key = cacheKey(rawValue) else { return nil }
    return imageCache.object(forKey: key as NSString)
  }

  static func cache(_ image: UIImage, for rawValue: String?) {
    guard let key = cacheKey(rawValue) else { return }
    let pixelW = max(1, Int(image.size.width * image.scale))
    let pixelH = max(1, Int(image.size.height * image.scale))
    imageCache.setObject(image, forKey: key as NSString, cost: pixelW * pixelH * 4)
  }

  static func purge() {
    imageCache.removeAllObjects()
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
      let pixelW = max(1, Int(image.size.width * image.scale))
      let pixelH = max(1, Int(image.size.height * image.scale))
      imageCache.setObject(image, forKey: key as NSString, cost: pixelW * pixelH * 4)
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
  let archived: Bool
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
  let isArchiveEntry: Bool
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
  /// Profile tier for the peer. Claude/Codex are seeded server-side as `gold`.
  let peerTier: String?
  let previewRows: [[String: Any]]
  let initialMessages: [[String: Any]]
  /// Group/channel participant list (`[{userId, name, avatarUrl, role}]`), sent by
  /// the server for `isGroup` rows. Empty for DMs.
  let members: [[String: Any]]
  /// Epoch-millisecond timestamp of this chat's most recent activity (newest
  /// visible message, else room creation). Drives newest-first home ordering.
  /// Mirrors the server's `lastMessageAt`.
  let lastMessageAt: Double

  /// Explicit initializer (replaces the synthesized memberwise init) so
  /// `lastMessageAt` can default — every pre-existing `ChatHomeListRow(...)` call
  /// site keeps compiling and only the recency-aware paths pass a real value.
  init(
    chatId: String,
    title: String,
    preview: String,
    timeLabel: String,
    unreadCount: Int,
    markedUnread: Bool,
    muted: Bool,
    pinned: Bool,
    archived: Bool,
    isTyping: Bool,
    isOnline: Bool,
    peerUserId: String?,
    avatarUri: String?,
    avatarFallback: String,
    avatarGradientStartLight: String?,
    avatarGradientEndLight: String?,
    avatarGradientStartDark: String?,
    avatarGradientEndDark: String?,
    isSavedMessages: Bool,
    isArchiveEntry: Bool,
    type: String?,
    isGroup: Bool,
    isAgentFriend: Bool,
    peerAgentId: String?,
    agentEventInboxMode: String?,
    peerTier: String?,
    previewRows: [[String: Any]],
    initialMessages: [[String: Any]],
    members: [[String: Any]],
    lastMessageAt: Double = 0
  ) {
    self.chatId = chatId
    self.title = title
    self.preview = preview
    self.timeLabel = timeLabel
    self.unreadCount = unreadCount
    self.markedUnread = markedUnread
    self.muted = muted
    self.pinned = pinned
    self.archived = archived
    self.isTyping = isTyping
    self.isOnline = isOnline
    self.peerUserId = peerUserId
    self.avatarUri = avatarUri
    self.avatarFallback = avatarFallback
    self.avatarGradientStartLight = avatarGradientStartLight
    self.avatarGradientEndLight = avatarGradientEndLight
    self.avatarGradientStartDark = avatarGradientStartDark
    self.avatarGradientEndDark = avatarGradientEndDark
    self.isSavedMessages = isSavedMessages
    self.isArchiveEntry = isArchiveEntry
    self.type = type
    self.isGroup = isGroup
    self.isAgentFriend = isAgentFriend
    self.peerAgentId = peerAgentId
    self.agentEventInboxMode = agentEventInboxMode
    self.peerTier = peerTier
    self.previewRows = previewRows
    self.initialMessages = initialMessages
    self.members = members
    self.lastMessageAt = lastMessageAt
  }

  var isBuiltInAgentSurface: Bool {
    Self.isBuiltInAgentChatId(chatId)
  }

  var isBridgeAgentSurface: Bool {
    Self.bridgeProvider(peerUserId: peerUserId, name: title, isAgent: isAgentFriend, agentId: peerAgentId) != nil
  }

  var isGoldTier: Bool {
    peerTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gold"
  }

  static func isBuiltInAgentChatId(_ rawChatId: String) -> Bool {
    switch rawChatId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "vibe", "vibe_agent", "vibeagent", "vibe-ai", "vibe_ai":
      return true
    default:
      return false
    }
  }

  static func bridgeProvider(
    peerUserId: String?,
    name: String?,
    isAgent: Bool,
    agentId: String? = nil
  ) -> String? {
    let peer = peerUserId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if peer == "11111111-1111-1111-1111-111111111111" { return "claude" }
    if peer == "22222222-2222-2222-2222-222222222222" { return "codex" }
    if peer == "33333333-3333-3333-3333-333333333333" { return "grok" }
    if peer == "44444444-4444-4444-4444-444444444444" { return "agy" }

    let agent = agentId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch agent {
    case "claude", "11111111-1111-1111-1111-111111111111":
      return "claude"
    case "codex", "22222222-2222-2222-2222-222222222222":
      return "codex"
    case "grok", "33333333-3333-3333-3333-333333333333":
      return "grok"
    case "agy", "antigravity", "44444444-4444-4444-4444-444444444444":
      return "agy"
    default:
      break
    }

    guard isAgent else { return nil }
    switch name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "claude": return "claude"
    case "codex": return "codex"
    case "grok": return "grok"
    case "agy", "antigravity": return "agy"
    default: return nil
    }
  }

  func cachePayload(messageLimit: Int = 5) -> [String: Any] {
    let shouldIncludeMessagePayload = messageLimit > 0 && !isBridgeAgentSurface
    var payload: [String: Any] = [
      "chatId": chatId,
      "title": title,
      "preview": isBridgeAgentSurface ? "Start session" : preview,
      "timeLabel": timeLabel,
      "unreadCount": unreadCount,
      "markedUnread": markedUnread,
      "muted": muted,
      "pinned": pinned,
      "archived": archived,
      "isTyping": isTyping,
      "isOnline": isOnline,
      "avatarFallback": avatarFallback,
      "isSavedMessages": isSavedMessages,
      "isArchiveEntry": isArchiveEntry,
      "isGroup": isGroup,
      "isAgentFriend": isAgentFriend,
      "previewRows": shouldIncludeMessagePayload ? previewRows : [],
      "messages": shouldIncludeMessagePayload ? Array(initialMessages.suffix(messageLimit)) : [],
      "lastMessageAt": lastMessageAt,
    ]
    if let peerUserId { payload["peerUserId"] = peerUserId }
    if let peerAgentId { payload["peerAgentId"] = peerAgentId }
    if let agentEventInboxMode { payload["agentEventInboxMode"] = agentEventInboxMode }
    if let peerTier { payload["peerTier"] = peerTier }
    if let avatarUri { payload["avatarUri"] = avatarUri }
    if let avatarGradientStartLight { payload["avatarGradientStartLight"] = avatarGradientStartLight }
    if let avatarGradientEndLight { payload["avatarGradientEndLight"] = avatarGradientEndLight }
    if let avatarGradientStartDark { payload["avatarGradientStartDark"] = avatarGradientStartDark }
    if let avatarGradientEndDark { payload["avatarGradientEndDark"] = avatarGradientEndDark }
    if let type { payload["type"] = type }
    return payload
  }

  func withPresence(isTyping: Bool, isOnline: Bool, preview: String? = nil) -> ChatHomeListRow {
    let bridgeSurface = isBridgeAgentSurface
    return ChatHomeListRow(
      chatId: chatId,
      title: title,
      preview: bridgeSurface ? "Start session" : (preview ?? self.preview),
      timeLabel: timeLabel,
      unreadCount: unreadCount,
      markedUnread: markedUnread,
      muted: muted,
      pinned: pinned,
      archived: archived,
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
      isArchiveEntry: isArchiveEntry,
      type: type,
      isGroup: isGroup,
      isAgentFriend: isAgentFriend,
      peerAgentId: peerAgentId,
      agentEventInboxMode: agentEventInboxMode,
      peerTier: peerTier,
      previewRows: bridgeSurface ? [] : previewRows,
      initialMessages: bridgeSurface ? [] : initialMessages,
      members: members,
      lastMessageAt: lastMessageAt
    )
  }

  static func parse(_ raw: [String: Any]) -> ChatHomeListRow? {
    guard let chatId = normalizedString(raw["chatId"] ?? raw["chat_id"]), !chatId.isEmpty else {
      return nil
    }
    let isSavedMessages = chatId == "saved_messages"
    let isArchiveEntry = parseBool(raw["isArchiveEntry"] ?? raw["is_archive_entry"]) ?? false
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
    let timeLabel =
      normalizedString(raw["timeLabel"] ?? raw["time_label"] ?? raw["time"])
      ?? serverMessages.last.map(homeTimeLabel(from:))
      ?? ""
    let unreadCount = parseInt(raw["unreadCount"] ?? raw["unread_count"]) ?? 0
    let markedUnread = parseBool(raw["markedUnread"] ?? raw["marked_unread"]) ?? false
    let muted = parseBool(raw["muted"]) ?? false
    let pinned = parseBool(raw["pinned"]) ?? false
    let archived = parseBool(raw["archived"]) ?? false
    let isTyping = parseBool(raw["isTyping"] ?? raw["is_typing"]) ?? false
    let isOnline = parseBool(raw["isOnline"] ?? raw["is_online"]) ?? false
    let type = normalizedString(raw["type"] ?? raw["chatType"] ?? raw["chat_type"])
    let isGroup =
      parseBool(raw["isGroup"] ?? raw["is_group"]) ?? (type == "group" || type == "channel")
    // Groups/channels are never a 1:1 with a "friend": ignore any friend_* fields. A stale
    // pre-fix cached row can still carry a leaked agent friendId/friendImage — that's what
    // made an old group open Codex AND show Codex's avatar instead of the uploaded photo.
    // Prefer the room's own avatar_url and never fall back to a member/friend image.
    let friendId =
      isGroup
      ? nil
      : normalizedString(
        raw["friendId"] ?? raw["friend_id"] ?? raw["peerUserId"] ?? raw["peer_user_id"]
          ?? raw["userId"] ?? raw["user_id"])
    let peerUserId = friendId
    let rawAvatar =
      isGroup
      ? normalizedString(
        raw["avatarUrl"] ?? raw["avatar_url"] ?? raw["avatarUri"] ?? raw["avatar_uri"])
      : normalizedString(
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
    let peerAgentId =
      isGroup
      ? nil
      : normalizedString(
        raw["friendAgentId"] ?? raw["friend_agent_id"] ?? raw["agentId"] ?? raw["agent_id"])
    // Bridge agents (Claude/Codex/Grok) are real users with is_agent=true but NO
    // Agent record (`peerAgentId` is nil). Treat reserved shadow-user ids as agents
    // even when the payload omits friendIsAgent, so Grok DMs route into the agent view.
    let isReservedBridgeAgent =
      Self.bridgeProvider(peerUserId: peerUserId, name: title, isAgent: true, agentId: peerAgentId)
      != nil
    let isAgentFriend =
      !isGroup
      && (Self.isBuiltInAgentChatId(chatId)
        || isReservedBridgeAgent
        || (parseBool(raw["friendIsAgent"] ?? raw["friend_is_agent"]) ?? (peerAgentId != nil)))
    let agentEventInboxMode = normalizedString(
      raw["friendAgentEventInboxMode"] ?? raw["friend_agent_event_inbox_mode"]
        ?? raw["agentEventInboxMode"] ?? raw["agent_event_inbox_mode"] ?? raw["eventInboxMode"]
        ?? raw["event_inbox_mode"])
    let peerTier = normalizedString(
      raw["friendTier"] ?? raw["friend_tier"] ?? raw["peerTier"] ?? raw["peer_tier"]
        ?? raw["tier"] ?? raw["badge"] ?? raw["badgeTier"] ?? raw["badge_tier"])
    let isBridgeAgent = Self.bridgeProvider(
      peerUserId: peerUserId,
      name: title,
      isAgent: isAgentFriend,
      agentId: peerAgentId
    ) != nil
    let preview = isBridgeAgent ? "Start session" : (previewRaw ?? previewMessage ?? "")
    let initialMessages = isBridgeAgent ? [] : serverMessages
    let previewRows = isBridgeAgent ? [] : parsePreviewRows(raw["previewRows"] ?? raw["preview_rows"])

    let lastMessageAt: Double = {
      if let value = raw["lastMessageAt"] as? NSNumber { return value.doubleValue }
      if let value = raw["last_message_at"] as? NSNumber { return value.doubleValue }
      if let text = normalizedString(raw["lastMessageAt"] ?? raw["last_message_at"]),
        let parsed = Double(text)
      {
        return parsed
      }
      // Cache/legacy payloads without the field: derive from the newest message.
      if let newest = serverMessages.last { return Double(parseTimestamp(newest)) }
      return 0
    }()

    return ChatHomeListRow(
      chatId: chatId,
      title: title,
      preview: preview,
      timeLabel: timeLabel,
      unreadCount: max(0, unreadCount),
      markedUnread: markedUnread,
      muted: muted,
      pinned: pinned,
      archived: archived,
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
      isArchiveEntry: isArchiveEntry,
      type: type,
      isGroup: isGroup,
      isAgentFriend: isAgentFriend,
      peerAgentId: peerAgentId,
      agentEventInboxMode: agentEventInboxMode,
      peerTier: peerTier,
      previewRows: previewRows,
      initialMessages: initialMessages,
      members: parsePreviewRows(raw["members"]),
      lastMessageAt: lastMessageAt
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

/// Shared builder for the "mosaic" group avatar — a composite tile made from up to
/// four members' avatars (photo where available, coloured initials otherwise).
///
/// Previously private to `ChatHomeCardCell`; now backs both the home list row AND
/// the group *profile* hero so the two surfaces show the exact same group image
/// (and share the `ChatAvatarImageStore` cache). Lives here alongside
/// `ChatAvatarURLResolver` so it stays in the app target without a new file ref.
enum GroupCompositeAvatar {
  struct Slot {
    let id: String
    let name: String
    let url: String?
  }

  /// Parse a raw members payload into avatar slots, tolerating the several key
  /// spellings the server/home use.
  static func slots(from members: [[String: Any]]) -> [Slot] {
    members.compactMap { member -> Slot? in
      let id =
        (member["userId"] as? String) ?? (member["id"] as? String)
        ?? (member["memberId"] as? String)
      guard let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      let name =
        ((member["name"] as? String) ?? (member["displayName"] as? String)
          ?? (member["username"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let rawURL =
        (member["avatarUrl"] as? String) ?? (member["avatar_url"] as? String)
        ?? (member["profileImage"] as? String) ?? (member["profile_image"] as? String)
      let url = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines)
      return Slot(id: id, name: name, url: (url?.isEmpty ?? true) ? nil : url)
    }
  }

  /// Stable, size-aware cache key for a set of slots (order-sensitive). Size is
  /// part of the key so the small home tile and the large profile hero don't
  /// clobber each other in `ChatAvatarImageStore`.
  static func cacheKey(for slots: [Slot], side: CGFloat) -> String {
    "group-composite:" + slots.map(\.id).joined(separator: ",") + "@\(Int(side))"
  }

  /// Fully build the composite for a members payload: parse → load member images
  /// concurrently → render → cache. Returns `nil` when there are fewer than two
  /// usable members (the caller should fall back to initials/single avatar).
  static func composedImage(
    members: [[String: Any]],
    side: CGFloat = 60,
    isDark: Bool
  ) async -> UIImage? {
    let usable = Array(slots(from: members).prefix(4))
    guard usable.count >= 2 else { return nil }

    let key = cacheKey(for: usable, side: side)
    if let cached = ChatAvatarImageStore.cached(for: key) { return cached }

    var images: [String: UIImage] = [:]
    await withTaskGroup(of: (String, UIImage?).self) { group in
      for slot in usable {
        guard let url = slot.url else { continue }
        group.addTask { (slot.id, await ChatAvatarImageStore.load(from: url)) }
      }
      for await (id, image) in group {
        if let image { images[id] = image }
      }
    }

    let composite = render(slots: usable, images: images, side: side, isDark: isDark)
    ChatAvatarImageStore.cache(composite, for: key)
    return composite
  }

  // MARK: - Rendering

  static func render(
    slots: [Slot], images: [String: UIImage], side: CGFloat, isDark: Bool
  ) -> UIImage {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = UIScreen.main.scale
    let size = CGSize(width: side, height: side)
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let rects = compositeRects(count: slots.count, side: side)
    let seam = (isDark ? UIColor.black : UIColor.white).withAlphaComponent(0.7)

    return renderer.image { rendererContext in
      let cg = rendererContext.cgContext
      for (index, slot) in slots.enumerated() where index < rects.count {
        let rect = rects[index]
        cg.saveGState()
        cg.addRect(rect)
        cg.clip()
        if let image = images[slot.id] {
          drawAspectFill(image, in: rect, context: cg)
        } else {
          colorForName(slot.name.isEmpty ? slot.id : slot.name).setFill()
          cg.fill(rect)
          drawInitials(initials(from: slot.name), in: rect, context: rendererContext, side: side)
        }
        cg.restoreGState()
      }
      // Thin seams between tiles.
      seam.setStroke()
      cg.setLineWidth(1)
      for rect in rects {
        cg.stroke(rect)
      }
    }
  }

  private static func compositeRects(count: Int, side: CGFloat) -> [CGRect] {
    let half = side / 2
    switch count {
    case 2:
      return [
        CGRect(x: 0, y: 0, width: half, height: side),
        CGRect(x: half, y: 0, width: half, height: side),
      ]
    case 3:
      return [
        CGRect(x: 0, y: 0, width: half, height: side),
        CGRect(x: half, y: 0, width: half, height: half),
        CGRect(x: half, y: half, width: half, height: half),
      ]
    default:
      return [
        CGRect(x: 0, y: 0, width: half, height: half),
        CGRect(x: half, y: 0, width: half, height: half),
        CGRect(x: 0, y: half, width: half, height: half),
        CGRect(x: half, y: half, width: half, height: half),
      ]
    }
  }

  private static func drawAspectFill(_ image: UIImage, in rect: CGRect, context cg: CGContext) {
    let imageSize = image.size
    guard imageSize.width > 0, imageSize.height > 0 else { return }
    let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
    let drawWidth = imageSize.width * scale
    let drawHeight = imageSize.height * scale
    let drawRect = CGRect(
      x: rect.midX - drawWidth / 2,
      y: rect.midY - drawHeight / 2,
      width: drawWidth,
      height: drawHeight)
    image.draw(in: drawRect)
    _ = cg
  }

  private static func drawInitials(
    _ text: String, in rect: CGRect, context: UIGraphicsImageRendererContext, side: CGFloat
  ) {
    guard !text.isEmpty else { return }
    let fontSize = min(rect.width, rect.height) * 0.42
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
      .foregroundColor: UIColor.white,
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributed.size()
    let origin = CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2)
    attributed.draw(at: origin)
  }

  private static func initials(from name: String) -> String {
    let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
    if parts.isEmpty { return "" }
    if parts.count == 1 {
      return String(parts[0].prefix(1)).uppercased()
    }
    let first = parts[0].prefix(1)
    let second = parts[1].prefix(1)
    return (String(first) + String(second)).uppercased()
  }

  private static func colorForName(_ seed: String) -> UIColor {
    var hash: UInt64 = 5381
    for byte in seed.utf8 {
      hash = (hash &* 33) &+ UInt64(byte)
    }
    let hue = CGFloat(hash % 360) / 360.0
    return UIColor(hue: hue, saturation: 0.55, brightness: 0.72, alpha: 1)
  }
}
