//
//  VibeAgentConversationView.swift
//  Vibe
//
//  The full-page agent surface. This is the screen pushed from a default-chat
//  agent bubble's "view agent" affordance: it shows the full conversation for a
//  single agent task (the user's prompt + the agent's reply) rendered with the
//  ported VibeAgentKit components — streaming text, the agent loader/orb, the
//  compact tool-progress feed, and the tappable progress sheet.
//
//  Design intent (per product direction):
//   - The page is NEVER empty: it is seeded with that task's prior messages
//     (the user prompt that started the task + the agent message), so opening
//     "view agent" lands you in the middle of the conversation, not a blank feed.
//   - The default chat list stays the multiplexing surface (one bubble per
//     prompt/task in groups); THIS view is single-task.
//
//  The Resolo `ChatView`/`ChatStore` (its networking + state layer) is NOT ported
//  — only the rendering primitives. Vibe owns the data and maps it in via
//  `VibeAgentKitMap` below, so we don't drag Resolo's backend into Vibe core.
//

import AVFoundation
import Speech
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Mapping: Vibe data -> VibeAgentKit render models

enum VibeAgentKitMap {

  /// Appearance matched to the app's warm-dark palette (the ported fallbacks were
  /// authored against the same palette, so they line up without retuning).
  static func appearance(for traitCollection: UITraitCollection) -> VibeAgentKitChatAppearance {
    traitCollection.userInterfaceStyle == .light ? .lightFallback : .fallback
  }

  /// One enriched tool node -> a progress item. The compact label
  /// (`chatAgentNodeCompactLabel`, shared with the chat-cell formatter) gives the
  /// Claude-Code-style "Read ChatEngine.swift", "Edit chat.ex  +12 −3" reading.
  /// `detail` is the decrypted per-action blob (command OUTPUT, todo contents);
  /// it becomes the row's expandable body in the tool sheet.
  static func progressItem(
    from node: ChatListRow.AgentProgressNode,
    detail: [String: Any]? = nil
  ) -> VibeAgentKitProgressItem {
    let kind = node.kind ?? (detail?["kind"] as? String)
    // bash carries its full (un-clipped) command; read carries the file slice it read;
    // edits carry a unified-diff patch. All ride the decrypted blob → the expand layers.
    let fullCommand = (detail?["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let patch = (detail?["patch"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawOutput = (detail?["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fileName = node.target ?? (detail?["name"] as? String)
    return VibeAgentKitProgressItem(
      label: chatAgentNodeCompactLabel(node),
      badges: [],
      eventType: "progress",
      recipient: nil,
      platform: nil,
      format: nil,
      messageContent: actionDetailBody(kind: kind, detail: detail),
      messagePreview: nil,
      voiceUrl: nil,
      voiceDuration: nil,
      status: node.status,
      isRecording: false,
      recordingStartTime: nil,
      tool: kind,
      image: nil,
      itemType: kind,
      sourceUrl: nil,
      nodeId: node.id,
      command: (fullCommand?.isEmpty == false) ? fullCommand : nil,
      patch: (patch?.isEmpty == false) ? patch : nil,
      fileName: fileName,
      fileContent: (kind == "read" && rawOutput?.isEmpty == false) ? rawOutput : nil,
      lineStart: node.start,
      lineEnd: node.end,
      parentId: node.parentId,
      subagentType: node.subagentType
    )
  }

  /// Decrypt a turn's sealed action array into `nodeId -> detail`. Server-opaque:
  /// without the phone-held key this is empty and rows show labels only.
  private static func actionDetailMap(for row: ChatListRow) -> [String: [String: Any]] {
    guard let enc = row.agentActionsEnc,
      let obj = AgentRuntimeCrypto.decrypt(enc),
      let actions = obj["actions"] as? [[String: Any]]
    else { return [:] }
    var map: [String: [String: Any]] = [:]
    for action in actions {
      if let id = action["id"] as? String, !id.isEmpty { map[id] = action }
    }
    return map
  }

  private static func imageAttachments(from row: ChatListRow) -> [VibeAgentKitImageAttachment] {
    var attachments: [VibeAgentKitImageAttachment] = []
    let rowId = row.messageId ?? row.key
    let sourceURI = (row.localMediaUrl?.isEmpty == false ? row.localMediaUrl : row.mediaUrl)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let isImageMessage =
      row.visualKind == .media
      && (row.messageType == "image"
        || row.messageType == "gif"
        || isImageReference(uri: sourceURI, fileName: row.fileName))
    if isImageMessage, let sourceURI, !sourceURI.isEmpty {
      attachments.append(
        VibeAgentKitImageAttachment(
          id: "\(rowId)#media",
          name: row.fileName,
          mime: mimeType(for: row.fileName ?? sourceURI),
          sourceURI: sourceURI,
          dataBase64: row.thumbnailBase64
        )
      )
    } else if isImageMessage, let thumb = row.thumbnailBase64, !thumb.isEmpty {
      attachments.append(
        VibeAgentKitImageAttachment(
          id: "\(rowId)#thumb",
          name: row.fileName,
          mime: "image/jpeg",
          sourceURI: nil,
          dataBase64: thumb
        )
      )
    }

    for (index, blob) in row.agentBridgeAttachmentsEnc.enumerated() {
      guard let object = AgentRuntimeCrypto.decrypt(blob) else { continue }
      let mime =
        normalizedString(object["mime"])
        ?? normalizedString(object["type"])
        ?? normalizedString(object["contentType"])
        ?? normalizedString(object["content_type"])
      let dataBase64 =
        normalizedString(object["dataB64"])
        ?? normalizedString(object["data_b64"])
        ?? normalizedString(object["base64"])
      let uri =
        normalizedString(object["uri"])
        ?? normalizedString(object["url"])
        ?? normalizedString(object["path"])
      let name =
        normalizedString(object["name"])
        ?? normalizedString(object["fileName"])
        ?? normalizedString(object["file_name"])
      let looksImage =
        (mime?.lowercased().hasPrefix("image/") == true)
        || dataBase64 != nil
        || isImageReference(uri: uri, fileName: name)
      guard looksImage else { continue }
      attachments.append(
        VibeAgentKitImageAttachment(
          id: "\(rowId)#bridge-image-\(index)",
          name: name,
          mime: mime ?? mimeType(for: name ?? uri ?? ""),
          sourceURI: uri,
          dataBase64: dataBase64
        )
      )
    }

    return attachments
  }

  private static func normalizedString(_ raw: Any?) -> String? {
    guard let raw else { return nil }
    let value: String
    if let string = raw as? String {
      value = string
    } else if let number = raw as? NSNumber {
      value = number.stringValue
    } else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func isImageReference(uri: String?, fileName: String?) -> Bool {
    let extensions = [uri, fileName].compactMap { value -> String? in
      guard let value, !value.isEmpty else { return nil }
      if let url = URL(string: value), !url.pathExtension.isEmpty {
        return url.pathExtension.lowercased()
      }
      let ext = (value as NSString).pathExtension.lowercased()
      return ext.isEmpty ? nil : ext
    }
    return extensions.contains { ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp"].contains($0) }
  }

  private static func mimeType(for value: String) -> String? {
    let ext: String
    if let url = URL(string: value), !url.pathExtension.isEmpty {
      ext = url.pathExtension.lowercased()
    } else {
      ext = (value as NSString).pathExtension.lowercased()
    }
    switch ext {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "heic", "heif": return "image/heic"
    case "bmp": return "image/bmp"
    default: return nil
    }
  }

  /// The decrypted detail rendered as the tool sheet row's expandable body: a
  /// command's OUTPUT, a todo checklist, search hits. Returns nil to leave the
  /// row as just its label (edits/reads need no body).
  private static func actionDetailBody(kind: String?, detail: [String: Any]?) -> String? {
    guard let detail else { return nil }
    let output = ((detail["output"] as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let clipped = output.count > 1400 ? String(output.prefix(1400)) + "\n… (truncated)" : output
    switch kind ?? (detail["kind"] as? String) ?? "" {
    case "todo":
      let todos = detail["todos"] as? [[String: Any]] ?? []
      guard !todos.isEmpty else { return nil }
      return todos.map { todo -> String in
        let content = (todo["content"] as? String) ?? ""
        switch (todo["status"] as? String) ?? "" {
        case "completed": return "✓ \(content)"
        case "in_progress": return "→ \(content)"
        default: return "• \(content)"
        }
      }.joined(separator: "\n")
    case "bash", "search", "web", "task", "tool", "thinking":
      return clipped.isEmpty ? nil : clipped
    default:
      return nil
    }
  }

  /// A chat row -> a render message. User rows render as right-side bubbles; agent
  /// rows render as the assistant body (streaming text + progress).
  static func chatMessage(from row: ChatListRow) -> VibeAgentKitChatMessage {
    let isUser = row.isMe && !row.isAgentMessage
    let isCompaction = row.isAgentMessage && row.agentMsgKind == "summary"
    let defaultBody = row.isAgentMessage ? (row.plainContent ?? row.text) : row.text
    // A /compact summary renders as a centered, collapsible divider — keep its RAW
    // summary text (the divider reveals it on tap); ordinary turns use their body.
    let body = isCompaction
      ? (row.plainContent ?? row.text).trimmingCharacters(in: .whitespacesAndNewlines)
      : defaultBody
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let isInterrupted = trimmedBody == "[Request interrupted by user]"
      || trimmedBody.localizedCaseInsensitiveContains("request interrupted by user")
    let hasBodyText = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    // A turn's tool actions render natively: each depth-0 node becomes a progress
    // item (compact shimmer line + tap-to-open tool sheet). The decrypted detail
    // (command OUTPUT, todo contents) becomes each row's expandable body.
    let detailMap: [String: [String: Any]] = row.isAgentMessage ? actionDetailMap(for: row) : [:]
    let items = row.isAgentMessage
      ? row.agentProgressNodes.filter { $0.depth == 0 }.map { progressItem(from: $0, detail: detailMap[$0.id]) }
      : []
    // Subagent (Claude Task tool) children: depth>=1 nodes grouped by their parent
    // Task node id. Kept out of the main feed; the read-only subagent view reads them.
    var subagentChildren: [String: [VibeAgentKitProgressItem]] = [:]
    if row.isAgentMessage {
      for node in row.agentProgressNodes where node.depth >= 1 {
        guard let parentId = node.parentId, !parentId.isEmpty else { continue }
        subagentChildren[parentId, default: []].append(progressItem(from: node, detail: detailMap[node.id]))
      }
    }
    let attachments = row.isAgentMessage ? [] : imageAttachments(from: row)
    // A turn delivered via the bridge-history path ("agentBridgeHistory") carries its
    // live state ONLY as a progress node whose status the bridge flipped to "running"
    // (markMessageRunning in vibe-bridge.js): the relayed metadata has no `isStreaming`
    // flag, and the runtime card is sealed/encrypted BEFORE the turn is marked live so
    // it still reads status:"done". Without keying off the node, a still-running history
    // turn arrives looking identical to a finished one — so the cell collapses it into a
    // "Worked · N steps" card instead of showing the live feed (the "still live but it
    // collapses, no live progress" bug). Every finished node gets an explicit
    // "done"/"error" status from foldTurnIntoHost, so a lone "running" node unambiguously
    // means the turn is in flight.
    let hasRunningNode = row.agentProgressNodes.contains { $0.status.lowercased() == "running" }
    let isLiveTurn = row.isAgentMessage && !isCompaction && !isInterrupted
      && (row.isStreamingText || hasRunningNode)
    return VibeAgentKitChatMessage(
      id: row.messageId ?? row.key,
      role: (isUser && !isInterrupted) ? .user : .assistant,
      text: body,
      timestamp: row.timestamp,
      timestampMs: 0,
      isStreaming: isLiveTurn,
      isError: row.status == "failed",
      hasFinalResponseText: row.isAgentMessage && !isLiveTurn && !isCompaction && !isInterrupted && hasBodyText,
      progress: [],
      progressItems: (isCompaction || isInterrupted) ? [] : items,
      subagentChildren: (isCompaction || isInterrupted) ? [:] : subagentChildren,
      sourceMessageId: (isCompaction || isInterrupted) ? nil : row.agentActionSourceId,
      runtime: (isCompaction || isInterrupted) ? nil : (row.isAgentMessage ? row.agentRuntime : nil),
      attachments: attachments,
      isCompactionSummary: isCompaction,
      systemDividerText: isInterrupted ? "[Request interrupted by user]" : nil
    )
  }

  /// Build the seed message list for a task. `rows` should already be the slice of
  /// chat rows that belong to this task (the prompt + the agent reply, and any
  /// prior turns when resumed).
  /// Max rows mapped at once. Each `chatMessage(from:)` performs per-row E2E decryption
  /// (actions + attachments) which, over hundreds of rows, blocks the main thread for
  /// seconds and overheats the device. Only the latest window is ever needed to continue.
  static let transcriptWindow = 40

  static func messages(from rows: [ChatListRow], limit: Int = transcriptWindow) -> [VibeAgentKitChatMessage] {
    // Decrypt/map only the most recent `limit` rows (the visible tail). Older turns load
    // on demand via History; mapping all of them is what froze the agent view.
    let windowed = rows.count > limit ? Array(rows.suffix(limit)) : rows
    // The same outgoing prompt can surface twice — once as the optimistic/native row and
    // again as a server- or session-history re-ingest under a DIFFERENT message id, which
    // slips past the id-based merge upstream and renders as a duplicate user bubble (one
    // pinned at the top, one down in the feed). Collapse a user bubble that exactly repeats
    // the previous kept user turn (only assistant/agent turns in between) — the real-world
    // signature of that double-ingest. A genuinely repeated identical prompt is the rare,
    // low-harm cost.
    var lastUserText: String?
    var result: [VibeAgentKitChatMessage] = []
    for row in windowed {
      guard case .message = row.kind else { continue }
      // Skip empty system/placeholder rows — but KEEP a freshly-started streaming
      // row even before it has text/steps/runtime, so the live "Working…" loader
      // appears the instant a run begins instead of the view looking like nothing
      // is happening.
      let m = chatMessage(from: row)
      // A runtime with only metadata (status, provider, model) but no diff is not
      // renderable — the cell's assistant body view hides everything, producing an
      // empty cell that creates a large scrollable gap in the history view. Only
      // treat the runtime as "real content" when it carries an actual file diff.
      let hasRenderableRuntime: Bool = {
        guard let rt = m.runtime, let diff = rt.diff else { return false }
        let hasPatch = diff.patch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return diff.filesChanged > 0 || diff.additions > 0 || diff.deletions > 0
          || !diff.files.isEmpty || hasPatch
      }()
      if m.text.isEmpty && m.progressItems.isEmpty && !hasRenderableRuntime && m.attachments.isEmpty && !m.isStreaming {
        continue
      }
      if m.role == .user, m.attachments.isEmpty {
        let trimmed = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          if trimmed == lastUserText { continue }  // duplicate of the previous user turn
          lastUserText = trimmed
        }
      }
      result.append(m)
    }
    return result
  }
}

// MARK: - Full-page agent conversation surface

final class VibeAgentConversationViewController: UIViewController, UITableViewDataSource,
  UITableViewDelegate, PHPickerViewControllerDelegate, UIGestureRecognizerDelegate
{

  private let tableView = UITableView(frame: .zero, style: .plain)
  private let progressSheet = VibeAgentKitAgentProgressSheetView()
  private let composerView = VibeComposerView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let liveDotView = UIView()
  private let liveLabel = UILabel()
  // Connection status indicator on the device subline (in-view header): solid green
  // pip when the computer is connected, red pip + spinner while reconnecting.
  private let connectionDotView = UIView()
  private let connectionSpinner = UIActivityIndicatorView(style: .medium)
  private var messages: [VibeAgentKitChatMessage]
  /// Bridge info-command results (executable == "vibe-bridge") are stored in `messages`
  /// for banner/catalog computations but suppressed from the table — they render in the
  /// glass overlay instead.
  private var tableMessages: [VibeAgentKitChatMessage] {
    messages.filter { msg in
      // Bridge info-command results render in the glass overlay, not the table.
      if msg.runtime?.command?.executable?.lowercased() == "vibe-bridge" { return false }
      // Skip agent messages that carry no renderable content: no text, no progress
      // items, no attachments, not streaming, and no runtime diff. Such messages
      // produce empty cells that create a scrollable gap (the "huge empty state" bug
      // when opening history).
      if msg.role == .assistant,
        !msg.isStreaming,
        !msg.isCompactionSummary,
        msg.systemDividerText == nil,
        msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        msg.progressItems.isEmpty,
        msg.attachments.isEmpty
      {
        let hasDiff: Bool = {
          guard let diff = msg.runtime?.diff else { return false }
          let hasPatch = diff.patch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
          return diff.filesChanged > 0 || diff.additions > 0 || diff.deletions > 0
            || !diff.files.isEmpty || hasPatch
        }()
        if !hasDiff { return false }
      }
      return true
    }
  }
  private var appearance: VibeAgentKitChatAppearance
  private let runtimeTitle: String
  private let runtimeSubtitle: String
  private let inputPlaceholder: String
  private let regeneratePrompt: String
  private let messagesProvider: (() -> [VibeAgentKitChatMessage])?
  private let onSend: ((String, AgentBridgeRunOptions, [String]) -> Void)?
  private var tableBottomConstraint: NSLayoutConstraint?
  private var composerBottomConstraint: NSLayoutConstraint?
  private var composerHeightConstraint: NSLayoutConstraint?
  private var toggleScrollLockDepth = 0
  private var changeObserver: NSObjectProtocol?
  private var keyboardObservers: [NSObjectProtocol] = []
  private let bottomEdgeFadeView = UIView()
  private let editToastBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let editToastIcon = UIImageView()
  private let editToastLabel = UILabel()
  private let usageBannerView = ChatPinnedBannerView()
  private var usageBannerVisible = false
  private var usageBannerKey: String?
  private let commandOverlayView = VibeAgentCommandOverlayView()

  // A short confirmation toast for composer actions that used to pop the (oversized,
  // unbounded-height) command overlay — `/usage` now just refreshes the pinned banner
  // above and confirms here instead; `/plan` confirms here instead of a local panel.
  private let infoToastBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let infoToastIcon = UIImageView()
  private let infoToastLabel = UILabel()
  private var infoToastHideWork: DispatchWorkItem?

  // Subagent (Claude Task tool) surfacing: a top toast announces a subagent starting,
  // and tapping it (or its feed row) opens a read-only detail view of its steps.
  private let subagentToastBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let subagentToastLabel = UILabel()
  private var subagentToastTarget: (messageId: String, nodeId: String)?
  private var subagentToastHideWork: DispatchWorkItem?
  private var toastedSubagentIds: Set<String> = []
  private weak var openSubagentDetail: VibeAgentSubagentDetailViewController?
  private var openSubagentRef: (messageId: String, nodeId: String)?

  // In-view header (the app hides the system nav bar, so this VC carries its own):
  // model name centered (tappable → model/thinking/speed), connected device beneath,
  // plus back / new-chat / overflow. Shown only when NOT embedded in a SwiftUI nav.
  private let headerBar = UIView()
  private let headerBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let headerBackButton = UIButton(type: .system)
  private let headerModelButton = UIButton(type: .system)
  private let headerNewChatButton = UIButton(type: .system)
  private let headerMenuButton = UIButton(type: .system)
  private let headerSeparator = UIView()
  private var headerHeightConstraint: NSLayoutConstraint?
  private var usesInViewHeader: Bool { !isEmbeddedInSwiftUI && !embeddedInChatHost }

  /// The header profile avatar — the SAME avatar as the main chat view (gradient +
  /// optional fetched picture), not a generic SF person glyph. The host seeds these so
  /// it can resolve the conversation's real avatar.
  private let headerAvatarView = VibeAgentHeaderAvatarView()
  var avatarTitle: String?
  var avatarPeerUserId: String?
  var avatarChatId: String?
  var avatarURI: String? { didSet { if isViewLoaded { refreshHeaderAvatar() } } }

  /// History button — its own standalone trailing element, immediately to the left of
  /// the profile avatar. Stays put when the new-chat button animates in/out.
  private lazy var headerHistoryButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.setImage(UIImage(systemName: "clock.arrow.circlepath"), for: .normal)
    btn.addTarget(self, action: #selector(historyTapped), for: .touchUpInside)
    btn.accessibilityLabel = "History"
    btn.setContentHuggingPriority(.required, for: .horizontal)
    btn.setContentCompressionResistancePriority(.required, for: .horizontal)
    return btn
  }()

  /// New-chat button — only present once a history/turn is loaded. It animates IN next
  /// to the history button (and out again) without disturbing history/profile.
  private lazy var headerNewChatActionButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.setImage(UIImage(systemName: "square.and.pencil"), for: .normal)
    btn.addTarget(self, action: #selector(newChatTapped), for: .touchUpInside)
    btn.accessibilityLabel = "New Chat"
    btn.setContentHuggingPriority(.required, for: .horizontal)
    btn.setContentCompressionResistancePriority(.required, for: .horizontal)
    return btn
  }()

  /// Container for ONLY history + new chat — the cloud (profile) is deliberately NOT in
  /// here; it stays its own standalone bar-button item. Arranged left→right as
  /// new chat, history, so new chat animates in hugging the history button while the
  /// cloud (a separate item further trailing) never shares a wrapper with them.
  private lazy var headerHistoryActionsStack: UIStackView = {
    let stack = UIStackView(arrangedSubviews: [
      headerNewChatActionButton, headerHistoryButton,
    ])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 16
    return stack
  }()

  /// Floating "jump to latest" control above the composer; appears when the feed is
  /// scrolled away from the bottom and snaps it back on tap.
  private let jumpToBottomButton = UIButton(type: .system)
  private var jumpToBottomBottomConstraint: NSLayoutConstraint?
  private var jumpButtonVisible = false
  /// One-shot guard so the feed lands pinned to the bottom on first appearance without a
  /// visible settle/shift as content size and insets resolve.
  private var hasPerformedInitialScroll = false
  /// Notified when the model/intelligence/speed selection changes so the header label
  /// stays in sync with the menu.
  private var selectionObserver: NSObjectProtocol?

  /// The model a loaded run reports (history list / live task). The header shows this
  /// when the user hasn't explicitly overridden the model, so a resumed/opened session
  /// reflects its real model instead of the local default.
  var runModel: String?
  /// Connected computer name shown beneath the model (e.g. "MacBook-Pro.local").
  var deviceLabel: String?
  /// Whether that computer is currently online (drives the "· reconnecting" hint).
  var deviceConnected: Bool = true

  /// True if a chat history was explicitly picked or a new message was sent.
  /// When false, the view hides messages and shows the "History" button instead of
  /// the standard "New Chat" / "Menu" actions.
  var isHistoryPicked: Bool = false {
    didSet {
      guard isViewLoaded else { return }
      updateNavigationButtons()
      updateRepoPickerStyle()
      updateEmptyState()
      tableView.reloadData()
      updateUsageBanner()
    }
  }

  /// Closure called when the user taps "History"
  var onPresentHistory: (() -> Void)?
  /// Closure called when the user taps the agent profile button.
  var onPresentProfile: (() -> Void)?

  /// A single centered spinner shown while a session's transcript is loading, instead
  /// of a fake "Loading conversation…" message bubble. Cleared as soon as rows render.
  private let loadingSpinner = VibeAgentArcSpinner()
  private let repoPickerButton = UIButton(type: .system)

  /// Menu assigned by the host (ChatListView) to display Repo/Permission/Report/History options.
  var repoPickerMenu: UIMenu? {
    didSet {
      repoPickerButton.menu = repoPickerMenu
      updateRepoPickerStyle()
    }
  }
  /// Centered welcome shown when the conversation is empty (and not loading): the agent
  /// chat surface lands here directly — a fresh chat with a clear "start typing" cue —
  /// rather than a separate history screen. Past sessions stay reachable via the nav
  /// buttons (new chat / menu); this just keeps the blank state from looking broken.
  private let emptyStateView = UIStackView()
  private let emptyStateIcon = UIImageView()
  private let emptyStateTitle = UILabel()
  private let emptyStateSubtitle = UILabel()
  private let emptyStateVisibleGuide = UILayoutGuide()
  var isLoadingTranscript = false {
    didSet {
      updateLoadingOverlay()
      updateUsageBanner()
    }
  }

  /// Tapping a message's progress row opens the full tool sheet for that message.
  /// Stashed so we know which message's items to present.
  private var progressItemsByMessageId: [String: [VibeAgentKitProgressItem]] = [:]

  /// Message ids whose "Worked · N steps" line is currently expanded inline.
  /// Persists across reloads so a live update doesn't collapse what the user opened.
  private var expandedProgressMessageIds: Set<String> = []
  private var expandedRuntimeMessageIds: Set<String> = []

  /// User message ids whose long prompt bubble is expanded. Long prompts collapse by
  /// default so the table does not inherit huge row heights or blank lower padding.
  private var expandedTextMessageIds: Set<String> = []

  /// Per-message set of step node-ids whose detail layer is open (the command/result
  /// box, the edit patch, the read file slice). Keyed by message id → node ids; persists
  /// across reloads so a live tick doesn't re-collapse a step the user drilled into.
  private var expandedStepIdsByMessage: [String: Set<String>] = [:]

  /// When each still-streaming turn was first seen as live. The "Working · M:SS" clock
  /// reads from this so it counts up steadily and NEVER restarts as new chunks arrive
  /// (a fresh `Date()` per chunk was what made the timer appear to reset).
  private var streamStartByMessageId: [String: Date] = [:]
  /// Optimistic rows inserted locally immediately after send. The real transport rows
  /// replace them once ChatEngine/bridge state catches up.
  private var localMessageOrder: [String] = []
  private var localMessagesById: [String: VibeAgentKitChatMessage] = [:]
  private var localWorkingMessageIdBySourceId: [String: String] = [:]

  /// Start a fresh conversation with the agent (clears the on-screen transcript and
  /// begins a new, non-resumed task). When nil the trailing "new chat" button is
  /// hidden — set by hosts where a new chat is meaningful (the bridge runtime view).
  var onNewChat: (() -> Void)?

  /// Back/close hook. When set (the isolated full-screen DM agent surface hosted as a
  /// child of ChatConversationController), the header back button calls this instead of
  /// pop/dismiss so the host can return to the chat surface. Nil for pushed/modal use.
  var onClose: (() -> Void)?

  /// True when this surface is the DM's PRIMARY entry — opened because the agent's Default
  /// view is "Agent", not a "See progress" drill-down from the chat surface. The host wires
  /// Back to exit the whole DM straight to Home in this case (rather than peeling back to the
  /// chat view underneath), so the agent reads as its own page, not a layer over chat.
  var isPrimaryAgentSurface = false

  /// Host hook invoked when the user picks "Edit" on a message — after the VC has
  /// reverted the turn's file changes and before it refills the composer. Hosts use
  /// it to reset into a fresh task so the revised prompt re-runs cleanly (rather than
  /// resuming the old turn). The Edit action itself is gated on `agentBridgeChatId`.
  var onEditMessage: ((VibeAgentKitChatMessage) -> Void)?

  /// If true, this controller is embedded in a SwiftUI view (like AgentBridgeRuntimeView)
  /// and the SwiftUI NavigationStack will manage the navigation bar and header.
  var isEmbeddedInSwiftUI = false

  /// True when hosted in-place inside ChatMainView's bridge DM surface. The shared chat
  /// header (the model + device glass pills) provides the chrome, so this VC suppresses
  /// its own in-view header and just fills the body with the runtime feed + composer —
  /// switching chat⇄agent then has no present/dismiss shift.
  var embeddedInChatHost = false

  /// Chat + provider context (history surface) so a runtime card can route a
  /// full-file-open request to the user's bridge. Nil in the live agent view.
  var agentBridgeChatId: String?
  var agentBridgeProvider: String? {
    didSet {
      composerView.provider = agentBridgeProvider ?? "codex"
      if isViewLoaded { updateHeaderTexts() }
    }
  }

  init(
    title: String,
    subtitle: String = "",
    messages: [VibeAgentKitChatMessage],
    regeneratePrompt: String = "",
    inputPlaceholder: String? = nil,
    messagesProvider: (() -> [VibeAgentKitChatMessage])? = nil,
    onSend: ((String, AgentBridgeRunOptions, [String]) -> Void)? = nil
  ) {
    self.messages = messages
    self.runtimeTitle = title
    self.runtimeSubtitle = subtitle
    self.inputPlaceholder = inputPlaceholder ?? "Ask \(title)"
    self.regeneratePrompt = regeneratePrompt
    self.messagesProvider = messagesProvider
    self.onSend = onSend
    self.appearance = .fallback
    super.init(nibName: nil, bundle: nil)
    self.title = title
  }

  required init?(coder: NSCoder) { return nil }

  deinit {
    if let changeObserver {
      NotificationCenter.default.removeObserver(changeObserver)
    }
    if let selectionObserver {
      NotificationCenter.default.removeObserver(selectionObserver)
    }
    keyboardObservers.forEach(NotificationCenter.default.removeObserver)
  }

  @objc func closeTapped() {
    if let onClose {
      onClose()
      return
    }
    if let nav = navigationController, nav.viewControllers.first !== self {
      nav.popViewController(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  private func configureNewChatButton(animated: Bool = false) {
    guard !isEmbeddedInSwiftUI, !embeddedInChatHost else { return }
    installHeaderActionsItem()
    updateHeaderActionButtons(animated: animated)
  }

  /// Install TWO separate trailing items: the cloud (profile) as its own standalone
  /// element at the trailing edge, and — to its left, after a gap — the history + new
  /// chat group. Keeping the cloud out of the group is what makes it read as a single
  /// independent element instead of being warped together with the action buttons.
  private func installHeaderActionsItem() {
    headerAvatarView.removeTarget(self, action: #selector(profileTapped), for: .touchUpInside)
    headerAvatarView.addTarget(self, action: #selector(profileTapped), for: .touchUpInside)
    refreshHeaderAvatar()
    // Already installed? The history/new-chat group is the trailing-most custom stack.
    if navigationItem.rightBarButtonItems?.last?.customView === headerHistoryActionsStack {
      return
    }
    let profileItem = UIBarButtonItem(customView: headerAvatarView)
    profileItem.accessibilityLabel = "Profile"
    let gap = UIBarButtonItem(barButtonSystemItem: .fixedSpace, target: nil, action: nil)
    gap.width = 12
    let actionsItem = UIBarButtonItem(customView: headerHistoryActionsStack)
    actionsItem.accessibilityLabel = "Agent actions"
    // Index 0 = trailing edge: cloud sits alone at the edge, gap, then history group.
    navigationItem.rightBarButtonItems = [profileItem, gap, actionsItem]
  }

  /// Show/hide the new-chat button next to history. Animating only this arranged
  /// subview keeps the profile + history anchored to the trailing edge while new chat
  /// slides/fades in beside the history button.
  private func updateHeaderActionButtons(animated: Bool) {
    let targetHidden = !isHistoryPicked
    guard headerNewChatActionButton.isHidden != targetHidden else {
      headerNewChatActionButton.alpha = targetHidden ? 0 : 1
      return
    }
    if animated {
      if !targetHidden { headerNewChatActionButton.alpha = 0 }
      navigationController?.navigationBar.setNeedsLayout()
      UIView.animate(
        withDuration: 0.28, delay: 0,
        usingSpringWithDamping: 0.86, initialSpringVelocity: 0.4,
        options: [.curveEaseInOut, .allowUserInteraction]
      ) {
        self.headerNewChatActionButton.isHidden = targetHidden
        self.headerNewChatActionButton.alpha = targetHidden ? 0 : 1
        self.headerHistoryActionsStack.layoutIfNeeded()
        // Let the nav bar re-place the (now wider/narrower) history group so the cloud
        // and history stay put and only new chat moves.
        self.navigationController?.navigationBar.layoutIfNeeded()
      }
    } else {
      headerNewChatActionButton.isHidden = targetHidden
      headerNewChatActionButton.alpha = targetHidden ? 0 : 1
    }
  }

  /// Feed the header avatar the conversation's real identity so it renders the same
  /// gradient/picture as the main chat view (falls back to the runtime title).
  private func refreshHeaderAvatar() {
    headerAvatarView.configure(
      title: avatarTitle ?? runtimeTitle,
      peerUserId: avatarPeerUserId,
      chatId: avatarChatId,
      avatarURI: avatarURI,
      isDark: appearance.isDark
    )
  }

  private func updateNavigationButtons() {
    if !isEmbeddedInSwiftUI && !embeddedInChatHost {
      // Only animate if the view is already on screen (window != nil) so it doesn't
      // animate on initial load.
      let animated = viewIfLoaded?.window != nil
      configureNewChatButton(animated: animated)
    } else {
      buildInViewHeader()
    }
  }


  @objc private func historyTapped() {
    onPresentHistory?()
  }

  @objc private func profileTapped() {
    onPresentProfile?()
  }

  @objc private func handleTranscriptTap() {
    view.endEditing(true)
  }

  // The dismiss tap lives on the root view; let it coexist with the table's own
  // gestures and ignore touches that land inside the composer (so typing / its buttons
  // keep working while a tap anywhere else dismisses the keyboard).
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    guard let touched = touch.view else { return true }
    return !touched.isDescendant(of: composerView)
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    true
  }

  @objc private func jumpToBottomTapped() {
    scrollToBottom(animated: true)
    setJumpButtonVisible(false)
  }

  @objc private func newChatTapped() {
    startNewChat()
  }

  private func startNewChat() {
    expandedProgressMessageIds.removeAll()
    expandedRuntimeMessageIds.removeAll()
    expandedTextMessageIds.removeAll()
    expandedStepIdsByMessage.removeAll()
    progressItemsByMessageId.removeAll()
    streamStartByMessageId.removeAll()
    localMessageOrder.removeAll()
    localMessagesById.removeAll()
    localWorkingMessageIdBySourceId.removeAll()
    messages = []
    isLoadingTranscript = false
    isHistoryPicked = false
    tableView.reloadData()
    updateNavigationLiveState()
    updateLoadingOverlay()
    updateEditToast()
    updateUsageBanner(force: true)
    hideCommandOverlay()
    onNewChat?()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Let the feed extend under the (now translucent) nav bar and the bottom edge so
    // content flows edge-to-edge and the bars read as seamless blur — no opaque block.
    edgesForExtendedLayout = .all
    extendedLayoutIncludesOpaqueBars = true
    appearance = VibeAgentKitMap.appearance(for: traitCollection)
    view.backgroundColor = appearance.background
    configureNavigationTitle()
    configureNewChatButton()

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.backgroundColor = appearance.background
    tableView.separatorStyle = .none
    tableView.dataSource = self
    tableView.delegate = self
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 96.0
    tableView.keyboardDismissMode = .interactive
    // Bottom is driven by `updateScrollInsets()` (tracks the composer + keyboard); top
    // keeps a little breathing room under the translucent nav bar.
    tableView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
    tableView.register(VibeAgentKitMessageCell.self, forCellReuseIdentifier: VibeAgentKitMessageCell.reuseIdentifier)
    tableView.register(
      VibeAgentKitCompactionCell.self,
      forCellReuseIdentifier: VibeAgentKitCompactionCell.reuseIdentifier)
    view.addSubview(tableView)

    // Tap anywhere outside the composer to dismiss the keyboard. Installed on the ROOT
    // view (not just the table) so a tap in the empty feed area or under the composer's
    // own glass row still dismisses; the delegate excludes touches inside the composer so
    // the text view / its buttons keep working. `cancelsTouchesInView = false` keeps cell
    // taps and links alive.
    let dismissTap = UITapGestureRecognizer(target: self, action: #selector(handleTranscriptTap))
    dismissTap.cancelsTouchesInView = false
    dismissTap.delegate = self
    view.addGestureRecognizer(dismissTap)

    composerView.translatesAutoresizingMaskIntoConstraints = false
    composerView.applyAppearance(appearance)
    composerView.placeholder = inputPlaceholder
    composerView.provider = agentBridgeProvider ?? "codex"
    composerView.onSend = { [weak self] text, options in
      guard let self else { return }
      self.isHistoryPicked = true
      self.onSend?(text, options, self.composerView.consumePendingAttachments())
    }
    composerView.onCommand = { [weak self] command in
      guard let self else { return }
      let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      self.handleComposerCommand(trimmed)
    }
    composerView.onAttach = { [weak self] in
      self?.presentImageAttachmentPicker()
    }
    composerView.onStop = { [weak self] in
      self?.stopActiveTask()
    }
    composerView.onHeightChanged = { [weak self] height in
      self?.updateComposerHeight(height, animated: true)
    }
    view.addSubview(composerView)

    setupEditToast()

    repoPickerButton.translatesAutoresizingMaskIntoConstraints = false
    repoPickerButton.showsMenuAsPrimaryAction = true
    updateRepoPickerStyle()
    view.addSubview(repoPickerButton)

    progressSheet.translatesAutoresizingMaskIntoConstraints = false
    progressSheet.applyAppearance(appearance)
    progressSheet.isHidden = true
    view.addSubview(progressSheet)

    loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
    loadingSpinner.color = appearance.textSecondary
    loadingSpinner.isHidden = true
    view.addSubview(loadingSpinner)

    setupEmptyState()
    setupUsageBanner()
    setupCommandOverlay()
    setupSubagentToast()
    setupInfoToast()

    // Pin the feed to the TRUE bottom so messages scroll UNDER the floating composer
    // (Resolo-style, no hard footer line). `updateScrollInsets()` keeps a bottom
    // content inset equal to the composer's covered height so the last bubble clears
    // the pill, and grows it with the keyboard.
    let tableBottomConstraint = tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    // Pin the composer's bottom to the KEYBOARD LAYOUT GUIDE, not the view bottom. The
    // guide tracks the keyboard natively — including the interactive swipe-to-dismiss drag
    // — so the composer rides with the keyboard frame-for-frame instead of being animated
    // separately by notifications (which left it "stuck in the middle" on a swipe-down).
    // `usesBottomSafeArea = false` collapses the guide to the view's true bottom when the
    // keyboard is offscreen, so the composer still owns its home-indicator inset there.
    view.keyboardLayoutGuide.usesBottomSafeArea = false
    let composerBottomConstraint = composerView.bottomAnchor.constraint(
      equalTo: view.keyboardLayoutGuide.topAnchor)
    let composerHeightConstraint = composerView.heightAnchor.constraint(equalToConstant: composerView.preferredHeight)
    self.tableBottomConstraint = tableBottomConstraint
    self.composerBottomConstraint = composerBottomConstraint
    self.composerHeightConstraint = composerHeightConstraint

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableBottomConstraint,
      composerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      composerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      composerBottomConstraint,
      composerHeightConstraint,
      editToastBlur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      editToastBlur.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.leadingAnchor, constant: 16.0),
      editToastBlur.trailingAnchor.constraint(
        lessThanOrEqualTo: view.trailingAnchor, constant: -16.0),
      editToastBlur.bottomAnchor.constraint(equalTo: composerView.topAnchor, constant: -8.0),
      repoPickerButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16.0),
      repoPickerButton.bottomAnchor.constraint(equalTo: composerView.topAnchor, constant: -8.0),
      progressSheet.topAnchor.constraint(equalTo: view.topAnchor),
      progressSheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      progressSheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      progressSheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      loadingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      loadingSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      usageBannerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18.0),
      usageBannerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18.0),
      usageBannerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8.0),
      usageBannerView.heightAnchor.constraint(equalToConstant: ChatPinnedBannerView.preferredHeight),
      commandOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18.0),
      commandOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18.0),
      commandOverlayView.bottomAnchor.constraint(equalTo: composerView.topAnchor, constant: -10.0),
    ])

    view.addLayoutGuide(emptyStateVisibleGuide)
    NSLayoutConstraint.activate([
      emptyStateVisibleGuide.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      emptyStateVisibleGuide.bottomAnchor.constraint(equalTo: composerView.topAnchor),
      emptyStateVisibleGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyStateVisibleGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      emptyStateView.centerXAnchor.constraint(equalTo: emptyStateVisibleGuide.centerXAnchor),
      emptyStateView.centerYAnchor.constraint(
        equalTo: emptyStateVisibleGuide.centerYAnchor, constant: -16.0),
      emptyStateView.leadingAnchor.constraint(
        greaterThanOrEqualTo: emptyStateVisibleGuide.leadingAnchor, constant: 40.0),
      emptyStateView.trailingAnchor.constraint(
        lessThanOrEqualTo: emptyStateVisibleGuide.trailingAnchor, constant: -40.0),
    ])

    updateEmptyState()

    bottomEdgeFadeView.translatesAutoresizingMaskIntoConstraints = false
    bottomEdgeFadeView.isUserInteractionEnabled = false
    view.insertSubview(bottomEdgeFadeView, belowSubview: composerView)
    NSLayoutConstraint.activate([
      bottomEdgeFadeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomEdgeFadeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomEdgeFadeView.bottomAnchor.constraint(equalTo: composerView.bottomAnchor),
      bottomEdgeFadeView.topAnchor.constraint(equalTo: composerView.topAnchor, constant: -48),
    ])
    updateBottomEdgeFade()
    setupJumpToBottomButton()

    // Configure model popup on load
    DispatchQueue.main.async { [weak self] in
      self?.refreshModelMenu()
    }

    trackStreamStarts(messages)
    indexProgress()
    observeKeyboard()
    observeLiveMessages()
    // First landing is handled in viewDidLayoutSubviews (once content + insets resolve)
    // so the feed opens pinned to the bottom with no visible settle/shift.
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    applyNavigationAppearance()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    view.endEditing(true)
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    // SwiftUI host nav stack restores its own appearance AFTER viewWillAppear (during
    // the UIKit appearance sequence, not before). viewIsAppearing fires later — after
    // SwiftUI has committed its layout pass — so our transparent bar wins.
    applyNavigationAppearance()
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    if traitCollection.userInterfaceStyle != previous?.userInterfaceStyle {
      appearance = VibeAgentKitMap.appearance(for: traitCollection)
      view.backgroundColor = appearance.background
      tableView.backgroundColor = appearance.background
      progressSheet.applyAppearance(appearance)
      composerView.applyAppearance(appearance)
      commandOverlayView.applyAppearance(appearance)
      loadingSpinner.color = appearance.textSecondary
      updateEditToastAppearance()
      updateInfoToastAppearance()
      if !isEmbeddedInSwiftUI {
        applyNavigationAppearance()
      }
      refreshHeaderAvatar()
      updateJumpButtonAppearance()
      updateBottomEdgeFade()
      updateEmptyState()
      updateUsageBanner(force: true)
      tableView.reloadData()
    }
  }

  // MARK: Live updates

  func appendLocalPendingTurn(messageId: String, body: String) {
    let id = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { return }
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayBody = trimmedBody.isEmpty ? "Please take a look at the attached image." : trimmedBody
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    upsertLocalMessage(
      VibeAgentKitChatMessage(
        id: id,
        role: .user,
        text: displayBody,
        timestamp: "",
        timestampMs: nowMs
      )
    )
    let workingId = "local-working-\(id)"
    localWorkingMessageIdBySourceId[id] = workingId
    upsertLocalMessage(
      VibeAgentKitChatMessage(
        id: workingId,
        role: .assistant,
        text: "",
        timestamp: "",
        timestampMs: nowMs + 1,
        isStreaming: true
      )
    )
    setMessages(messages)
  }

  private func upsertLocalMessage(_ message: VibeAgentKitChatMessage) {
    localMessagesById[message.id] = message
    if !localMessageOrder.contains(message.id) {
      localMessageOrder.append(message.id)
    }
  }

  private func removeLocalMessage(_ id: String) {
    localMessagesById.removeValue(forKey: id)
    localMessageOrder.removeAll { $0 == id }
  }

  private func mergeLocalMessages(into incoming: [VibeAgentKitChatMessage]) -> [VibeAgentKitChatMessage] {
    let incomingIds = Set(incoming.map(\.id))
    for id in incomingIds where localMessagesById[id] != nil {
      removeLocalMessage(id)
    }

    var resolvedWorkingSources: [(sourceId: String, workingId: String)] = []
    for (sourceId, workingId) in localWorkingMessageIdBySourceId {
      let hasSourceLinkedReply = incoming.contains { message in
        !message.role.isUser
          && !message.id.hasPrefix("local-working-")
          && message.sourceMessageId == sourceId
      }
      let hasAdjacentReply: Bool = {
        guard let sourceIndex = incoming.firstIndex(where: { $0.id == sourceId }) else { return false }
        let replyStart = incoming.index(after: sourceIndex)
        return replyStart < incoming.endIndex
          && incoming[replyStart...].contains { message in
            !message.role.isUser && !message.id.hasPrefix("local-working-")
          }
      }()
      let hasRealReply = hasSourceLinkedReply || hasAdjacentReply
      guard hasRealReply else { continue }
      resolvedWorkingSources.append((sourceId, workingId))
    }
    for resolved in resolvedWorkingSources {
      let sourceId = resolved.sourceId
      let workingId = resolved.workingId
      removeLocalMessage(workingId)
      localWorkingMessageIdBySourceId.removeValue(forKey: sourceId)
    }

    let local = localMessageOrder.compactMap { id -> VibeAgentKitChatMessage? in
      guard !incomingIds.contains(id) else { return nil }
      return localMessagesById[id]
    }
    return incoming + local
  }

  /// Replace the rendered messages (e.g. when the agent stream advances). Cheap
  /// reload is fine here — the surface is single-task and short.
  func setMessages(_ incomingMessages: [VibeAgentKitChatMessage]) {
    let newMessages = mergeLocalMessages(into: incomingMessages)
    guard newMessages != messages else { return }
    if !isHistoryPicked,
      newMessages.contains(where: { $0.isStreaming || $0.runtime?.status == "running" })
    {
      isHistoryPicked = true
    }

    // Intercept newly arrived bridge info-command results. `/usage` gets a toast (the
    // pinned usage banner, refreshed below by `updateUsageBanner()`, already carries the
    // detail) instead of the old unbounded-height overlay, which could grow to cover the
    // whole screen for a long result; everything else still uses the overlay.
    let previousIds = Set(messages.map(\.id))
    for msg in newMessages where msg.runtime?.command?.executable?.lowercased() == "vibe-bridge"
      && !previousIds.contains(msg.id)
    {
      if bridgeCommandName(msg) == "usage" {
        showInfoToast(title: "Usage updated", systemImage: "gauge.with.dots.needle.bottom.50percent")
      } else {
        showBridgeCommandResult(msg)
      }
    }

    let wasNearBottom = isNearBottom()
    // Capture the pre-update rendered rows (bridge commands excluded) for the pure-append
    // check and to diff per-row content on the in-place streaming path.
    let oldTableMessages = tableMessages
    let oldTableIds = oldTableMessages.map(\.id)
    messages = newMessages
    let liveIds = Set(newMessages.map(\.id))
    expandedTextMessageIds = expandedTextMessageIds.filter { liveIds.contains($0) }
    expandedProgressMessageIds = expandedProgressMessageIds.filter { liveIds.contains($0) }
    expandedStepIdsByMessage = expandedStepIdsByMessage.filter { liveIds.contains($0.key) }
    // Real rows arrived → drop the centered loading spinner.
    if !newMessages.isEmpty { isLoadingTranscript = false }
    trackStreamStarts(newMessages)
    indexProgress()
    updateEditToast()
    updateSubagentState(newMessages)
    updateNavigationLiveState()
    updateLoadingOverlay()
    updateUsageBanner()
    updateComposerCommandCatalog()

    // A pure append (new turns pushed onto the end — the typical "send") animates the
    // new rows in and scrolls up, matching Resolo's push-in feel. Anything else
    // (streaming edits to existing rows, replacements, reorders) falls back to a plain
    // reload so the streaming label and bubble geometry stay correct.
    let newTableIds = tableMessages.map(\.id)
    let isPureAppend =
      newTableIds.count > oldTableIds.count && Array(newTableIds.prefix(oldTableIds.count)) == oldTableIds
    // A fresh user send = the last rendered row is a user message whose id is new. Pin it
    // to the top with room reserved below for the streaming answer (ChatGPT-style) instead
    // of scrolling to the bottom.
    let newUserSendId = tableMessages.last { $0.role.isUser && !oldTableIds.contains($0.id) }?.id
    if let newUserSendId { pushToTopUserId = newUserSendId }
    // The pinned turn has finished once its answer is no longer streaming.
    let turnStillLive = tableMessages.contains { $0.isStreaming || $0.runtime?.status == "running" }
    if pushToTopUserId != nil, !turnStillLive, newUserSendId == nil {
      pushToTopUserId = nil
      pushToTopReserve = 0
      pushToTopDetached = false
      pinAnimationDeadline = nil
    }
    // A streaming delta to the SAME rows (ids unchanged) is the common live case.
    let isContentOnlyUpdate = !newTableIds.isEmpty && newTableIds == oldTableIds
    if isHistoryPicked, isPureAppend, tableView.window != nil, tableView.numberOfRows(inSection: 0) == oldTableIds.count {
      let inserted = (oldTableIds.count..<newTableIds.count).map { IndexPath(row: $0, section: 0) }
      tableView.performBatchUpdates {
        // `.none` — we drive the appearance ourselves so the new bubble springs up from
        // below as the previous messages slide up (Resolo's on-send morph), instead of a
        // flat fade.
        tableView.insertRows(at: inserted, with: .none)
      } completion: { [weak self] _ in
        guard let self else { return }
        self.animateSentRows(inserted)
        if let id = newUserSendId {
          self.pinUserMessageToTop(id: id, animated: true)
        } else if self.pushToTopUserId != nil {
          // Pinned turn growing: the reserve shrinks passively in updateScrollInsets as the
          // answer streams in; just refresh the inset (no scroll move — the question holds).
          self.updateScrollInsets()
          self.reassertPinnedOffsetIfNeeded()
        } else if wasNearBottom {
          self.scrollToBottom(animated: true)
        }
      }
    } else if isContentOnlyUpdate, isHistoryPicked, tableView.window != nil,
      tableView.numberOfRows(inSection: 0) == newTableIds.count
    {
      // Content-only update (streaming deltas to existing rows): reconfigure the on-screen
      // cells IN PLACE instead of reloadData(). A full reload dequeues fresh cells every
      // frame, which remounts the whole turn and — because prepareForReuse wipes the
      // streaming label's incremental-reveal state — re-fades the ENTIRE answer on each
      // delta (the "flicker / extra fade" bug). Reusing the live cell instance lets the
      // label fade in only the newly-arrived characters.
      for indexPath in tableView.indexPathsForVisibleRows ?? [] {
        let row = indexPath.row
        guard row < tableMessages.count else { continue }
        // Only touch rows whose content actually changed (the streaming turn). Leaving
        // finished rows untouched stops them from rebuilding (and re-fading) every frame.
        if row < oldTableMessages.count, oldTableMessages[row] == tableMessages[row] { continue }
        reconfigureVisibleCell(at: indexPath)
      }
      // Pick up the new self-sized heights without a reload or a competing animation, so
      // the answer grows smoothly under the pinned question (top stays anchored).
      UIView.performWithoutAnimation {
        tableView.beginUpdates()
        tableView.endUpdates()
      }
      // Always recompute the bottom inset. While the question is pinned this shrinks the
      // reserve as the answer grows; once the turn finishes (pin cleared above) it lets the
      // reserve collapse back to the base inset — otherwise a short final answer leaves the
      // full-screen reserve behind as a big empty stretch you can scroll into (the "double
      // gap" bug: the send reserves a screen, the finished agent answer never fills it).
      updateScrollInsets()
      if pushToTopUserId == nil, wasNearBottom {
        scrollToBottom(animated: false)
      } else {
        reassertPinnedOffsetIfNeeded()
      }
    } else {
      tableView.reloadData()
      // Materialize real self-sized heights BEFORE any reserve/offset math below.
      // Right after reloadData the table only has ESTIMATED heights (96pt/row), which
      // undercount the content below the pinned question — computedPushToTopReserve
      // then re-inflates the bottom inset into a big scrollable dead gap on every
      // update that lands on this branch (it collapsed again as soon as any inline
      // toggle forced a real layout, which is exactly the reported flicker cycle).
      if tableView.window != nil {
        UIView.performWithoutAnimation { tableView.layoutIfNeeded() }
      }
      if let id = newUserSendId {
        pinUserMessageToTop(id: id, animated: true)
      } else {
        // Pinned turn growing: the reserve shrinks passively here. Finished turn: the
        // reserve collapses back to the base inset (same anti-"double gap" reset as above).
        updateScrollInsets()
        if pushToTopUserId == nil, wasNearBottom {
          scrollToBottom(animated: true)
        } else {
          reassertPinnedOffsetIfNeeded()
        }
      }
    }
  }

  /// Resolo-style send morph: the freshly inserted bubble(s) spring up from a small
  /// downward offset (with a quick fade) while `scrollToBottom` slides the earlier
  /// messages up — so a send reads as the previous message being pushed up by the new one.
  private func animateSentRows(_ inserted: [IndexPath]) {
    let cells = inserted.compactMap { indexPath -> UITableViewCell? in
      guard indexPath.row < tableMessages.count, tableMessages[indexPath.row].role.isUser else {
        return nil
      }
      return tableView.cellForRow(at: indexPath)
    }
    guard !cells.isEmpty else { return }
    for cell in cells {
      cell.transform = CGAffineTransform(translationX: 0, y: 22)
      cell.alpha = 0
    }
    UIView.animate(
      withDuration: 0.42,
      delay: 0,
      usingSpringWithDamping: 0.82,
      initialSpringVelocity: 0.4,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      for cell in cells {
        cell.transform = .identity
        cell.alpha = 1
      }
    }
  }

  func setTranscriptLoading(_ loading: Bool) {
    if loading {
      isHistoryPicked = true
      // A fresh session is loading — re-arm the one-shot so its first laid-out rows land
      // pinned to the bottom (no settle), just like the initial open.
      hasPerformedInitialScroll = false
    }
    isLoadingTranscript = loading
    updateRepoPickerStyle()
    updateEmptyState()
    updateUsageBanner()
  }

  private func observeLiveMessages() {
    selectionObserver = NotificationCenter.default.addObserver(
      forName: AgentBridgeSelectionStore.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.updateRepoPickerStyle()
    }

    guard messagesProvider != nil else { return }
    changeObserver = NotificationCenter.default.addObserver(
      forName: ChatEngine.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self else { return }
      self.refreshFromProvider()
      if (note.userInfo?["reason"] as? String) == "agentBridgeAsk" {
        self.handleAgentBridgeAsk(note.userInfo ?? [:])
      }
    }
  }

  /// A plan-approval / question request arrived from the bridge for this chat.
  /// Decrypt the sealed body and present the approval/ask sheet (once per request).
  private func handleAgentBridgeAsk(_ info: [AnyHashable: Any]) {
    let infoChatId = (info["chatId"] as? String) ?? ""
    let infoRequestId = (info["requestId"] as? String) ?? ""
    NSLog(
      "[AgentView][ask] handle ENTER vcChat=%@ infoChat=%@ requestId=%@ kind=%@",
      agentBridgeChatId ?? "nil", infoChatId, infoRequestId, (info["kind"] as? String) ?? "nil"
    )
    guard let chatId = agentBridgeChatId, !chatId.isEmpty else {
      NSLog("[AgentView][ask] DROP — vc has no agentBridgeChatId")
      return
    }
    guard infoChatId == chatId else {
      NSLog("[AgentView][ask] DROP — chatId mismatch vc=%@ info=%@", chatId, infoChatId)
      return
    }
    // Every agent session — Claude AND Codex, every run — ingests into the SAME DM
    // chatId (sessions are isolated only by a `bridge-<sessionId>-` message prefix).
    // So a chatId match alone lets the OTHER provider's ask surface on this page.
    // Scope to this page's provider too, so a Codex ask can't pop up on the Claude
    // page (and vice-versa). Only drop when both sides name a provider and disagree.
    let infoProvider =
      (info["provider"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let vcProvider =
      (agentBridgeProvider ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !infoProvider.isEmpty, !vcProvider.isEmpty, infoProvider != vcProvider {
      NSLog(
        "[AgentView][ask] DROP — provider mismatch vc=%@ info=%@ requestId=%@",
        vcProvider, infoProvider, infoRequestId)
      return
    }
    guard !infoRequestId.isEmpty else {
      NSLog("[AgentView][ask] DROP — empty requestId")
      return
    }
    let requestId = infoRequestId
    guard let payload = ChatEngine.shared.latestAgentBridgeAsk(requestId: requestId) else {
      NSLog("[AgentView][ask] DROP — no stored payload for requestId=%@", requestId)
      return
    }

    // The body is E2E-sealed (`askEnc`); fall back to plaintext `request` for a
    // keyless pairing. Decrypted shape is { kind, request: {...} }.
    var body: [String: Any]
    if let dec = AgentRuntimeCrypto.decrypt(payload["askEnc"]) {
      body = dec
    } else if let raw = payload["request"] as? [String: Any] {
      body = ["request": raw]
    } else {
      NSLog(
        "[AgentView][ask] DROP — decrypt failed AND no plaintext request (sealed=%@) requestId=%@",
        payload["askEnc"] != nil ? "Y" : "N", requestId
      )
      return
    }
    let kind = (body["kind"] as? String) ?? (info["kind"] as? String) ?? "ask"
    let request = (body["request"] as? [String: Any]) ?? body
    // Cross-surface dedup: claim once so the bubble surface (or another agent view)
    // doesn't also present this same ask.
    guard ChatEngine.shared.claimAgentBridgeAskPresentation(requestId: requestId) else {
      NSLog("[AgentView][ask] DROP — already claimed by another surface requestId=%@", requestId)
      return
    }
    NSLog("[AgentView][ask] PRESENT sheet kind=%@ requestId=%@ reqKeys=%@", kind, requestId, request.keys.joined(separator: ","))
    presentAskSheet(
      requestId: requestId,
      kind: kind,
      provider: info["provider"] as? String,
      request: request
    )
  }

  private func presentAskSheet(requestId: String, kind: String, provider: String?, request: [String: Any]) {
    let sheet = VibeAgentAskSheetViewController(kind: kind, request: request, appearance: appearance)
    sheet.onResolve = { [weak self] decision, answer in
      self?.resolveAgentBridgeAsk(
        requestId: requestId,
        kind: kind,
        provider: provider,
        request: request,
        decision: decision,
        answer: answer
      )
    }
    sheet.onDismissWithoutResolve = {
      ChatEngine.shared.releaseAgentBridgeAskPresentation(requestId: requestId)
    }
    if let presentation = sheet.sheetPresentationController {
      presentation.detents = [.medium(), .large()]
      presentation.prefersGrabberVisible = true
      presentation.preferredCornerRadius = 22
    }
    // If this VC is already presenting (e.g. an attachment picker or a prior sheet) the
    // new present() is dropped silently — surface that so we can see it in the logs.
    if let existing = presentedViewController {
      NSLog(
        "[AgentView][ask] WARN already presenting %@ — presenting ask sheet on top may fail",
        String(describing: type(of: existing))
      )
    }
    NSLog("[AgentView][ask] calling present() inWindow=%@ requestId=%@",
      view.window != nil ? "Y" : "N", requestId)
    present(sheet, animated: true) {
      NSLog("[AgentView][ask] present() completed requestId=%@", requestId)
    }
  }

  /// Send the answer back to the bridge and, for an approved plan, kick off the
  /// implementation run on the proven send path (edits enabled, resuming the
  /// plan's session). A rejection with feedback asks the agent to revise the plan.
  private func resolveAgentBridgeAsk(
    requestId: String,
    kind: String,
    provider: String?,
    request: [String: Any],
    decision: String,
    answer: [String: Any]?
  ) {
    var payload: [String: Any] = [
      "chatId": agentBridgeChatId ?? "",
      "requestId": requestId,
      "decision": decision,
    ]
    if let provider, !provider.isEmpty { payload["provider"] = provider }
    if let answer, !answer.isEmpty { payload["answer"] = answer }
    _ = ChatEngine.shared.sendAgentBridgeAskResponse(payload)

    guard kind == "plan" else { return }
    let resolvedProvider = agentBridgeProvider ?? "codex"
    let feedback = (answer?["feedback"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    if decision == "approve" {
      // Approving means the user is OK with edits → switch out of plan mode so the
      // implementation turn can actually change files.
      AgentBridgeSelectionStore.setWorkMode(.allowEdits)
      let options = AgentBridgeSelectionStore.selectedRunOptions(provider: resolvedProvider)
      var prompt = "The plan above is approved. Implement it now, end to end."
      if let feedback, !feedback.isEmpty { prompt += "\n\nAdditional guidance:\n\(feedback)" }
      if let plan = (request["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !plan.isEmpty
      {
        prompt += "\n\nApproved plan:\n\(plan)"
      }
      onSend?(prompt, options, [])
      reloadLiveMessages()
    } else if decision == "reject", let feedback, !feedback.isEmpty {
      // Stay in plan mode and revise — the new plan re-triggers approval.
      let options = AgentBridgeSelectionStore.selectedRunOptions(provider: resolvedProvider)
      onSend?("Please revise the plan based on this feedback, then present the updated plan:\n\(feedback)", options, [])
      reloadLiveMessages()
    }
  }

  private func refreshFromProvider() {
    guard let messagesProvider else { return }
    let next = messagesProvider()
    guard !next.isEmpty else { return }
    setMessages(next)
  }

  /// Pull the latest rows into the feed on demand. Used right after a send from this
  /// surface: the chat list appends the outgoing bubble synchronously (no engine
  /// `didChange` fires for the optimistic native row), so without an explicit poke
  /// the user's message would only appear in the chat view, not here.
  func reloadLiveMessages() {
    refreshFromProvider()
  }

  private func configureNavigationTitle() {
    // The embedded (profile) path gets its header from the SwiftUI NavigationStack
    // toolbar; only the standalone/chat presentations build the in-view header.
    guard usesInViewHeader else { return }
    buildInViewHeader()
  }

  private func buildInViewHeader() {
    navigationController?.setNavigationBarHidden(false, animated: false)

    let titleStack = UIStackView()
    titleStack.axis = .vertical
    titleStack.alignment = .center

    let subtitleStack = UIStackView(arrangedSubviews: [connectionDotView, connectionSpinner, subtitleLabel])
    subtitleStack.spacing = 4
    subtitleStack.alignment = .center

    var modelCfg = UIButton.Configuration.plain()
    modelCfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
    modelCfg.imagePlacement = .trailing
    modelCfg.imagePadding = 4
    modelCfg.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    // Keep the model name on ONE line — the nav bar's centered title slot is narrow
    // (back + 2–3 right items), so a wrapping title char-breaks ("Op / us"). Truncate
    // instead of wrapping, and let the label resist compression so it keeps its width.
    modelCfg.titleLineBreakMode = .byTruncatingTail
    headerModelButton.configuration = modelCfg
    headerModelButton.titleLabel?.numberOfLines = 1
    headerModelButton.titleLabel?.lineBreakMode = .byTruncatingTail
    headerModelButton.titleLabel?.adjustsFontSizeToFitWidth = true
    headerModelButton.titleLabel?.minimumScaleFactor = 0.85
    headerModelButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    headerModelButton.showsMenuAsPrimaryAction = true
    headerModelButton.accessibilityLabel = "Model and run options"

    titleStack.addArrangedSubview(headerModelButton)
    titleStack.addArrangedSubview(subtitleStack)

    // Connection pip + spinner
    connectionDotView.layer.cornerRadius = 3
    connectionDotView.layer.cornerCurve = .continuous
    connectionDotView.translatesAutoresizingMaskIntoConstraints = false
    connectionSpinner.translatesAutoresizingMaskIntoConstraints = false
    connectionSpinner.hidesWhenStopped = true
    connectionSpinner.transform = CGAffineTransform(scaleX: 0.62, y: 0.62)

    subtitleLabel.font = UIFont.systemFont(ofSize: 11.5, weight: .medium)
    subtitleLabel.textAlignment = .left
    subtitleLabel.lineBreakMode = .byTruncatingTail

    NSLayoutConstraint.activate([
      connectionDotView.widthAnchor.constraint(equalToConstant: 6),
      connectionDotView.heightAnchor.constraint(equalToConstant: 6)
    ])

    navigationItem.titleView = titleStack

    if onClose != nil {
      let backButton = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain, target: self, action: #selector(closeTapped))
      navigationItem.leftBarButtonItem = backButton
    }

    installHeaderActionsItem()
    updateHeaderActionButtons(animated: false)
    updateHeaderTexts()
  }

  /// Latest model a run in this conversation reported (the bridge sends
  /// `metadata.model`). Used so the header shows the real model (Opus / GPT-5.5 …) even
  /// when the user hasn't explicitly picked one — instead of the bare provider name.
  private var latestRuntimeModel: String? {
    for message in messages.reversed() {
      if let model = message.runtime?.model?.trimmingCharacters(in: .whitespacesAndNewlines),
        !model.isEmpty
      {
        return model
      }
    }
    return nil
  }

  /// Refresh the header's model title + run-options menu and the device subline.
  private func updateHeaderTexts() {
    guard usesInViewHeader else { return }
    let provider = agentBridgeProvider ?? "codex"
    let selected = AgentBridgeSelectionStore.selectedModel(provider: provider)
    let modelTitle = AgentBridgeSelectionStore.modelTitle(
      provider: provider, model: selected ?? runModel ?? latestRuntimeModel)

    headerModelButton.setTitle(modelTitle, for: .normal)
    let color = vibeAgentKitColorWithAlpha(appearance.text, 0.8)
    headerModelButton.setTitleColor(color, for: .normal)
    headerModelButton.tintColor = color
    headerModelButton.menu = runOptionsMenu()

    // Compact device name; the connection state is shown by the pip/spinner, not text.
    let device = (deviceLabel?.isEmpty == false) ? deviceLabel : AgentPairingService.lastDeviceLabel
    let connected = (deviceLabel != nil) ? deviceConnected : AgentPairingService.lastConnected
    let deviceText = (device?.isEmpty == false) ? device : runtimeSubtitle
    subtitleLabel.text = deviceText
    subtitleLabel.textColor = appearance.textSecondary

    let hasDevice = (deviceText ?? "").isEmpty == false
    let isReconnecting = !connected && hasDevice

    if isReconnecting {
      connectionDotView.isHidden = true
      connectionSpinner.color = appearance.textSecondary
      connectionSpinner.startAnimating()
    } else {
      connectionSpinner.stopAnimating()
      connectionDotView.isHidden = !hasDevice
      connectionDotView.backgroundColor = UIColor(red: 0.16, green: 0.78, blue: 0.45, alpha: 1)
    }
  }

  private func runOptionsMenu() -> UIMenu {
    let provider = agentBridgeProvider ?? "codex"
    let options = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
    let effectiveModelId =
      options.model
      ?? AgentBridgeSelectionStore.canonicalModel(
        provider: provider, model: runModel ?? latestRuntimeModel)

    let modelActions = AgentBridgeSelectionStore.modelChoices(provider: provider).map { choice in
      UIAction(
        title: choice.title,
        subtitle: choice.subtitle,
        state: choice.value == effectiveModelId ? .on : .off
      ) { [weak self] _ in
        AgentBridgeSelectionStore.setModel(provider: provider, model: choice.value)
        self?.updateHeaderTexts()
      }
    }
    let defaultAction = UIAction(
      title: "\(AgentBridgeSelectionStore.defaultModelTitle(provider: provider)) default",
      subtitle: "Use the model active in the local CLI session",
      state: effectiveModelId == nil ? .on : .off
    ) { [weak self] _ in
      AgentBridgeSelectionStore.setModel(provider: provider, model: nil)
      self?.runModel = nil
      self?.updateHeaderTexts()
    }
    let intelligenceActions = AgentBridgeIntelligenceLevel.allCases.map { level in
      UIAction(title: level.title, state: options.intelligence == level ? .on : .off) { [weak self] _ in
        AgentBridgeSelectionStore.setIntelligence(level)
        self?.updateHeaderTexts()
      }
    }
    let speedActions = AgentBridgeSpeedMode.allCases.map { speed in
      UIAction(title: speed.title, state: options.speed == speed ? .on : .off) { [weak self] _ in
        AgentBridgeSelectionStore.setSpeed(speed)
        self?.updateHeaderTexts()
      }
    }
    let currentTitle = AgentBridgeSelectionStore.modelTitle(
      provider: provider, model: options.model ?? runModel ?? latestRuntimeModel)
    return UIMenu(children: [
      UIMenu(title: "Model", subtitle: currentTitle, children: [defaultAction] + modelActions),
      UIMenu(title: "Thinking", subtitle: options.intelligence.title, children: intelligenceActions),
      UIMenu(title: "Speed", subtitle: options.speed.title, children: speedActions),
    ])
  }

  private func refreshModelMenu() {
    headerModelButton.menu = runOptionsMenu()
  }

  private func applyNavigationAppearance() {
    connectionSpinner.color = appearance.textSecondary
    subtitleLabel.textColor = appearance.textSecondary

    headerModelButton.tintColor = appearance.text
    var cfg = headerModelButton.configuration ?? .plain()
    cfg.baseForegroundColor = appearance.text
    headerModelButton.configuration = cfg

    // Embedded (SwiftUI nav) path — keep the bar fully transparent so the feed flows
    // under it edge-to-edge.
    titleLabel.textColor = appearance.text
    let transparent = UINavigationBarAppearance()
    transparent.configureWithTransparentBackground()
    transparent.backgroundColor = .clear
    transparent.shadowColor = .clear
    transparent.titleTextAttributes = [.foregroundColor: appearance.text]
    navigationController?.navigationBar.standardAppearance = transparent
    navigationController?.navigationBar.scrollEdgeAppearance = transparent
    navigationController?.navigationBar.compactAppearance = transparent
    navigationController?.navigationBar.compactScrollEdgeAppearance = transparent
    navigationController?.navigationBar.isTranslucent = true
    navigationController?.navigationBar.tintColor = appearance.text
  }

  private func updateNavigationLiveState() {
    let isLive = messages.contains { message in
      message.isStreaming || message.runtime?.status == "running"
    }
    // The composer's trailing control becomes STOP while a task is live (cancel the
    // running bridge run) and reverts to send/mic once it finishes — so an active turn
    // can never be sent over, and the user can always interrupt it.
    composerView.setTaskActive(isLive)
    // In-view header: the model can change as runs report it, so refresh the header
    // (model title + connection pip) whenever the message set advances.
    if usesInViewHeader {
      updateHeaderTexts()
      return
    }
    liveDotView.isHidden = !isLive
    liveLabel.isHidden = !isLive
    subtitleLabel.isHidden = runtimeSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func updateComposerHeight(_ height: CGFloat, animated: Bool) {
    composerHeightConstraint?.constant = height
    guard animated else {
      view.layoutIfNeeded()
      return
    }
    // `onHeightChanged` now fires from inside `VibeComposerView`'s own expand/collapse
    // animation closure, so most of the time we're already inside an active transaction
    // here — just ride it. Wrapping our OWN `UIView.animate` on top of that (a second,
    // differently-timed spring) is what used to make the pill and the keyboard visibly
    // fall out of sync ("jumping"). Only start a fresh spring when nothing is animating
    // yet (e.g. a safe-area-only change that didn't go through that closure).
    guard UIView.inheritedAnimationDuration <= 0 else {
      view.layoutIfNeeded()
      return
    }
    UIView.animate(
      withDuration: 0.38,
      delay: 0,
      usingSpringWithDamping: 0.82,
      initialSpringVelocity: 0.0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) { self.view.layoutIfNeeded() }
  }

  // MARK: Image attachments

  private func presentImageAttachmentPicker() {
    var config = PHPickerConfiguration()
    config.filter = .images
    config.selectionLimit = 4
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    for result in results {
      let provider = result.itemProvider
      guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
      provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
        guard let self, let image = object as? UIImage,
          let blob = Self.sealedImageBlob(from: image)
        else { return }
        DispatchQueue.main.async { self.composerView.addAttachment(blob: blob) }
      }
    }
  }

  /// Downscale + JPEG-encode so the encrypted blob is small enough to ride inside a
  /// chat message, then seal it with the pairing key so the server only relays an
  /// opaque payload. The daemon decrypts it and writes the file for the agent to read.
  static func sealedImageBlob(from image: UIImage) -> String? {
    let scaled = scaledImage(image, maxDimension: 1024)
    guard let data = scaled.jpegData(compressionQuality: 0.55) else { return nil }
    let object: [String: Any] = [
      "name": "image-\(Int(Date().timeIntervalSince1970 * 1000)).jpg",
      "mime": "image/jpeg",
      "dataB64": data.base64EncodedString(),
    ]
    return AgentRuntimeCrypto.encrypt(object)
  }

  private static func scaledImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    guard longest > maxDimension, longest > 0 else { return image }
    let scale = maxDimension / longest
    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: newSize)
    return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
  }

  private func observeKeyboard() {
    // The composer is pinned to `view.keyboardLayoutGuide.topAnchor`, so UIKit moves it
    // with the keyboard natively (including the interactive swipe-to-dismiss drag) and
    // `viewDidLayoutSubviews` → `updateScrollInsets()` keeps the feed pinned to the bottom
    // in lockstep. We only listen for the keyboard's appearance to keep the last bubble in
    // view when it first rises (the guide animation does the rest).
    let center = NotificationCenter.default
    keyboardObservers.append(center.addObserver(
      forName: UIResponder.keyboardWillShowNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self, self.isNearBottom() else { return }
      DispatchQueue.main.async { self.scrollToBottom(animated: true) }
    })
  }

  private func indexProgress() {
    progressItemsByMessageId = [:]
    for message in messages where !message.progressItems.isEmpty {
      progressItemsByMessageId[message.id] = message.progressItems
    }
  }

  /// Stamp the moment each turn first appears as live so its "Working · M:SS" clock
  /// counts up from a fixed instant (not a fresh now-time on every re-push), and forget
  /// turns that finished or scrolled out of the transcript.
  private func trackStreamStarts(_ next: [VibeAgentKitChatMessage]) {
    let liveIds = Set(next.filter { $0.isStreaming }.map(\.id))
    for id in liveIds where streamStartByMessageId[id] == nil {
      streamStartByMessageId[id] = Date()
    }
    streamStartByMessageId = streamStartByMessageId.filter { liveIds.contains($0.key) }
  }

  // MARK: Table

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    isHistoryPicked ? tableMessages.count : 0
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let message = tableMessages[indexPath.row]
    // System dividers and /compact summaries are centered muted rows, not bubbles.
    // Compact summaries can expand; interruption/status dividers are static.
    if message.isCompactionSummary || message.systemDividerText != nil {
      let cell = tableView.dequeueReusableCell(
        withIdentifier: VibeAgentKitCompactionCell.reuseIdentifier,
        for: indexPath
      ) as! VibeAgentKitCompactionCell
      cell.backgroundColor = .clear
      cell.onToggle = message.isCompactionSummary ? { [weak self] in self?.toggleCompaction(for: message.id) } : nil
      cell.configure(
        text: message.text,
        title: message.systemDividerText ?? "Context compacted",
        expanded: expandedProgressMessageIds.contains(message.id),
        canExpand: message.isCompactionSummary,
        appearance: appearance
      )
      return cell
    }
    let cell = tableView.dequeueReusableCell(
      withIdentifier: VibeAgentKitMessageCell.reuseIdentifier,
      for: indexPath
    ) as! VibeAgentKitMessageCell
    cell.backgroundColor = .clear
    cell.selectionStyle = .none
    cell.onProgressTap = { [weak self] in self?.toggleProgress(for: message.id) }
    cell.onStepTap = { [weak self] nodeId in self?.toggleStepDetail(messageId: message.id, nodeId: nodeId) }
    cell.onOpenSubagent = { [weak self] nodeId in
      self?.presentSubagentView(messageId: message.id, parentNodeId: nodeId)
    }
    cell.onTextExpansionTap = { [weak self] in self?.toggleTextExpansion(for: message.id) }
    cell.onAttachmentTap = { [weak self] attachment in self?.presentImageAttachment(attachment) }
    cell.onToggleRuntimeExpand = { [weak self] in self?.toggleRuntimeExpand(for: message.id) }
    cell.onReviewTapped = { [weak self] in self?.presentRuntimeReview(message) }
    cell.onFileTapped = { [weak self] file in self?.presentRuntimeFile(file, message: message) }
    cell.configure(
      message: message,
      appearance: appearance,
      regeneratePrompt: regeneratePrompt,
      showsActions: false,
      isProgressExpanded: expandedProgressMessageIds.contains(message.id),
      expandedStepIds: expandedStepIdsByMessage[message.id] ?? [],
      isTextExpanded: expandedTextMessageIds.contains(message.id),
      isRuntimeExpanded: expandedRuntimeMessageIds.contains(message.id),
      streamingStartDate: message.isStreaming ? streamStartByMessageId[message.id] : nil,
      availableWidth: tableView.bounds.width
    )
    return cell
  }

  /// Reconfigure an already-visible cell in place for the content-only streaming path —
  /// reuses the live cell instance (and, crucially, its streaming-text reveal state)
  /// instead of a reloadData() remount that would re-fade the whole answer each delta.
  /// The tap closures wired when the cell was dequeued still target this row's (unchanged)
  /// message id, so they don't need re-binding here.
  private func reconfigureVisibleCell(at indexPath: IndexPath) {
    guard indexPath.row < tableMessages.count else { return }
    let message = tableMessages[indexPath.row]
    if message.isCompactionSummary || message.systemDividerText != nil {
      guard let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitCompactionCell else { return }
      cell.configure(
        text: message.text,
        title: message.systemDividerText ?? "Context compacted",
        expanded: expandedProgressMessageIds.contains(message.id),
        canExpand: message.isCompactionSummary,
        appearance: appearance
      )
      return
    }
    guard let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell else { return }
    cell.configure(
      message: message,
      appearance: appearance,
      regeneratePrompt: regeneratePrompt,
      showsActions: false,
      isProgressExpanded: expandedProgressMessageIds.contains(message.id),
      expandedStepIds: expandedStepIdsByMessage[message.id] ?? [],
      isTextExpanded: expandedTextMessageIds.contains(message.id),
      isRuntimeExpanded: expandedRuntimeMessageIds.contains(message.id),
      streamingStartDate: message.isStreaming ? streamStartByMessageId[message.id] : nil,
      availableWidth: tableView.bounds.width
    )
  }

  // MARK: Hold menu (Copy / Edit)

  // The system context menu provides the "mold" lift/blur (matching Resolo's
  // `.contextMenu`); a rounded targeted preview makes just the bubble lift, not the
  // whole row. Copy is always offered for text; Edit only for user messages in a
  // bridge-backed conversation (where a revert + fresh re-run is possible).
  func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard indexPath.row < tableMessages.count else { return nil }
    let message = tableMessages[indexPath.row]
    let cellText = (tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell)?.currentMessageText
    let text = (cellText?.isEmpty == false) ? cellText! : message.text
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let isUser = message.role.isUser
    let canEdit = isUser && agentBridgeChatId != nil && !trimmed.isEmpty
    guard !trimmed.isEmpty || canEdit else { return nil }

    return UIContextMenuConfiguration(identifier: indexPath as NSIndexPath, previewProvider: nil) {
      [weak self] _ in
      guard let self else { return nil }
      var actions: [UIMenuElement] = []
      if !trimmed.isEmpty {
        actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
          UIPasteboard.general.string = text
        })
      }
      if canEdit {
        actions.append(UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in
          // Defer so the menu finishes dismissing before we mutate the table / focus
          // the composer.
          DispatchQueue.main.async { self.beginEdit(message) }
        })
      }
      return actions.isEmpty ? nil : UIMenu(children: actions)
    }
  }

  /// "Edit" a user message: revert any file changes the turn it produced made (the
  /// bridge's file-aware revert), have the host reset to a fresh task, then refill the
  /// composer so the revised prompt re-runs cleanly from the reverted state.
  private func beginEdit(_ message: VibeAgentKitChatMessage) {
    revertTurn(after: message)
    onEditMessage?(message)
    composerView.beginEditing(with: message.text)
  }

  /// Find the agent turn this user message produced (the next assistant message with
  /// a revertible runtime) and ask the bridge to restore the files it changed. No-op
  /// when the turn changed nothing revertible (e.g. the repo was dirty beforehand).
  private func revertTurn(after message: VibeAgentKitChatMessage) {
    guard
      let chatId = agentBridgeChatId,
      let idx = messages.firstIndex(where: { $0.id == message.id })
    else { return }
    let turn = messages[messages.index(after: idx)...].first {
      !$0.role.isUser && $0.runtime != nil
    }
    guard
      let runtime = turn?.runtime,
      runtime.controls?.canRevert == true,
      let taskId = runtime.taskId, !taskId.isEmpty
    else { return }
    let provider = runtime.provider ?? agentBridgeProvider ?? "codex"
    _ = ChatEngine.shared.sendAgentBridgeControl([
      "chatId": chatId,
      "provider": provider,
      "action": "revert",
      "taskId": taskId,
    ])
  }

  /// Cancel the in-flight bridge run for this chat (SIGTERM → SIGKILL on the connected
  /// computer). Wired to the composer's STOP button, which only appears while a task is
  /// live. Prefers the live turn's taskId when present; the bridge also falls back to
  /// the single running task for this chat+provider when taskId is absent.
  private func stopActiveTask() {
    guard let chatId = agentBridgeChatId, !chatId.isEmpty else { return }
    let provider = agentBridgeProvider ?? "codex"
    let taskId = messages.first {
      $0.isStreaming || $0.runtime?.status == "running"
    }?.runtime?.taskId
    var payload: [String: Any] = [
      "chatId": chatId,
      "provider": provider,
      "action": "cancel",
    ]
    if let taskId, !taskId.isEmpty { payload["taskId"] = taskId }
    NSLog("[AgentView] stopActiveTask chat=%@ provider=%@ taskId=%@", chatId, provider, taskId ?? "nil")
    _ = ChatEngine.shared.sendAgentBridgeControl(payload)
  }

  func tableView(
    _ tableView: UITableView,
    previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    bubblePreview(for: configuration)
  }

  func tableView(
    _ tableView: UITableView,
    previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    bubblePreview(for: configuration)
  }

  private func bubblePreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
    guard
      let indexPath = configuration.identifier as? NSIndexPath,
      let cell = tableView.cellForRow(at: IndexPath(row: indexPath.row, section: indexPath.section))
        as? VibeAgentKitMessageCell
    else { return nil }
    return cell.bubblePreview()
  }

  private func toggleTextExpansion(for messageId: String) {
    if expandedTextMessageIds.contains(messageId) {
      expandedTextMessageIds.remove(messageId)
    } else {
      expandedTextMessageIds.insert(messageId)
    }
    guard let row = tableMessages.firstIndex(where: { $0.id == messageId }) else { return }
    let indexPath = IndexPath(row: row, section: 0)
    applyAnchoredRowChange(at: indexPath) {
      if let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell {
        cell.configure(
          message: tableMessages[row],
          appearance: appearance,
          regeneratePrompt: regeneratePrompt,
          showsActions: false,
          isProgressExpanded: expandedProgressMessageIds.contains(messageId),
          expandedStepIds: expandedStepIdsByMessage[messageId] ?? [],
          isTextExpanded: expandedTextMessageIds.contains(messageId),
          streamingStartDate: tableMessages[row].isStreaming ? streamStartByMessageId[messageId] : nil,
          availableWidth: tableView.bounds.width
        )
      }
    }
  }

  private func presentImageAttachment(_ attachment: VibeAgentKitImageAttachment) {
    if let image = VibeAgentKitAttachmentGridView.decodedImage(from: attachment) {
      presentImagePreview(image)
      return
    }
    guard let source = attachment.sourceURI?.trimmingCharacters(in: .whitespacesAndNewlines),
      !source.isEmpty
    else { return }
    Task { [weak self] in
      let image = await ChatAvatarImageStore.load(from: source)
      await MainActor.run {
        guard let self, let image else { return }
        self.presentImagePreview(image)
      }
    }
  }

  private func presentImagePreview(_ image: UIImage) {
    let host = UIHostingController(rootView: VibeAgentImagePreview(image: image))
    host.modalPresentationStyle = .fullScreen
    present(host, animated: true)
  }

  // MARK: Progress (inline expand)

  // Tapping "Worked · N steps" reveals/hides that turn's step list inline, in the
  // bubble (Claude-Code style). The expanded set persists across reloads, and the
  // table update keeps the tapped row anchored so the list does not jump.
  private func toggleProgress(for messageId: String) {
    if expandedProgressMessageIds.contains(messageId) {
      expandedProgressMessageIds.remove(messageId)
    } else {
      expandedProgressMessageIds.insert(messageId)
    }
    guard let row = tableMessages.firstIndex(where: { $0.id == messageId }) else { return }
    let indexPath = IndexPath(row: row, section: 0)
    // Reconfigure the visible cell in place (cheap, idempotent), then let the
    // table remeasure its new height. If the cell isn't on screen the set is
    // already updated, so cellForRowAt renders it expanded when it scrolls in.
    applyAnchoredRowChange(at: indexPath) {
      if let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell {
        cell.configure(
          message: tableMessages[row],
          appearance: appearance,
          regeneratePrompt: regeneratePrompt,
          showsActions: false,
          isProgressExpanded: expandedProgressMessageIds.contains(messageId),
          expandedStepIds: expandedStepIdsByMessage[messageId] ?? [],
          isTextExpanded: expandedTextMessageIds.contains(messageId),
          streamingStartDate: tableMessages[row].isStreaming ? streamStartByMessageId[messageId] : nil,
          availableWidth: tableView.bounds.width
        )
      }
    }
  }

  /// Apply an inline expand/collapse without letting UITableView "helpfully" scroll.
  /// The cell owns the visible y-translate; the table only remeasures the tapped row.
  private func applyAnchoredRowChange(at _: IndexPath, _ change: () -> Void) {
    let offset = tableView.contentOffset
    toggleScrollLockDepth += 1
    UIView.performWithoutAnimation {
      change()
      tableView.beginUpdates()
      tableView.endUpdates()
      tableView.layoutIfNeeded()
      tableView.setContentOffset(clampedContentOffset(offset), animated: false)
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      UIView.performWithoutAnimation {
        self.tableView.setContentOffset(self.clampedContentOffset(offset), animated: false)
      }
      self.toggleScrollLockDepth = max(0, self.toggleScrollLockDepth - 1)
    }
  }

  private func clampedContentOffset(_ offset: CGPoint) -> CGPoint {
    let minY = -tableView.adjustedContentInset.top
    let maxY = max(
      minY,
      tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
    )
    return CGPoint(x: offset.x, y: min(max(offset.y, minY), maxY))
  }

  // Tapping a /compact divider reveals or hides the kept summary, in place — same
  // anchored unfold as the other toggles, reusing the per-message expand set.
  private func toggleCompaction(for messageId: String) {
    if expandedProgressMessageIds.contains(messageId) {
      expandedProgressMessageIds.remove(messageId)
    } else {
      expandedProgressMessageIds.insert(messageId)
    }
    guard let row = tableMessages.firstIndex(where: { $0.id == messageId }) else { return }
    let indexPath = IndexPath(row: row, section: 0)
    applyAnchoredRowChange(at: indexPath) {
      if let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitCompactionCell {
        cell.configure(
          text: tableMessages[row].text,
          title: "Context compacted",
          expanded: expandedProgressMessageIds.contains(messageId),
          canExpand: true,
          appearance: appearance
        )
      }
    }
  }

  // Tapping one completed step row (command, edit, read) opens its detail inline
  // under that row. The parent "Worked" card stays expanded and the tapped row is
  // reconfigured in place, so file diffs do not leave the conversation surface.
  private func toggleStepDetail(messageId: String, nodeId: String) {
    var expanded = expandedStepIdsByMessage[messageId] ?? []
    if expanded.contains(nodeId) {
      expanded.remove(nodeId)
    } else {
      expanded.insert(nodeId)
    }
    if expanded.isEmpty {
      expandedStepIdsByMessage.removeValue(forKey: messageId)
    } else {
      expandedStepIdsByMessage[messageId] = expanded
    }
    expandedProgressMessageIds.insert(messageId)

    guard let row = tableMessages.firstIndex(where: { $0.id == messageId }) else { return }
    let indexPath = IndexPath(row: row, section: 0)
    applyAnchoredRowChange(at: indexPath) {
      if let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell {
        cell.configure(
          message: tableMessages[row],
          appearance: appearance,
          regeneratePrompt: regeneratePrompt,
          showsActions: false,
          isProgressExpanded: true,
          expandedStepIds: expanded,
          isTextExpanded: expandedTextMessageIds.contains(messageId),
          streamingStartDate: tableMessages[row].isStreaming ? streamStartByMessageId[messageId] : nil,
          availableWidth: tableView.bounds.width
        )
      }
    }
  }
  private func toggleRuntimeExpand(for messageId: String) {
    if expandedRuntimeMessageIds.contains(messageId) {
      expandedRuntimeMessageIds.remove(messageId)
    } else {
      expandedRuntimeMessageIds.insert(messageId)
    }
    guard let row = tableMessages.firstIndex(where: { $0.id == messageId }) else { return }
    let indexPath = IndexPath(row: row, section: 0)
    applyAnchoredRowChange(at: indexPath) {
      if let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell {
        cell.configure(
          message: tableMessages[row],
          appearance: appearance,
          regeneratePrompt: regeneratePrompt,
          showsActions: false,
          isProgressExpanded: expandedProgressMessageIds.contains(messageId),
          expandedStepIds: expandedStepIdsByMessage[messageId] ?? [],
          isTextExpanded: expandedTextMessageIds.contains(messageId),
          isRuntimeExpanded: expandedRuntimeMessageIds.contains(messageId),
          streamingStartDate: tableMessages[row].isStreaming ? streamStartByMessageId[messageId] : nil,
          availableWidth: tableView.bounds.width
        )
      }
    }
  }

  private func presentRuntimeReview(_ message: VibeAgentKitChatMessage) {
    guard let patch = message.runtime?.diff?.patch, !patch.isEmpty else { return }
    let diffView = VibeAgentDiffSheetView(patch: patch, fileName: nil)
    presentDiffSheet(diffView: diffView)
  }

  private func presentRuntimeFile(_ file: ChatListRow.AgentRuntimeFile, message: VibeAgentKitChatMessage) {
    guard let patch = message.runtime?.diff?.patch, !patch.isEmpty else { return }
    // VibeAgentDiffSheetView parses the whole patch but displays it. To show just one file,
    // we extract the file chunk using ChatNativeStreamingTextLabel's diffChunk helper,
    // or we just pass the whole patch and let the sheet handle it.
    // For now, we'll extract the chunk the same way AgentRuntimePatchPreviewController did:
    let chunk = diffChunk(for: file.path, patch: patch)
    let diffView = VibeAgentDiffSheetView(patch: chunk.isEmpty ? patch : chunk, fileName: file.name)
    presentDiffSheet(diffView: diffView)
  }

  private func presentDiffSheet(diffView: VibeAgentDiffSheetView) {
    let hostingController = UIHostingController(rootView: diffView)
    hostingController.modalPresentationStyle = .pageSheet
    if let sheet = hostingController.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 20
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    present(hostingController, animated: true)
  }

  private func diffChunk(for path: String, patch: String) -> String {
    let target = "diff --git a/\(path)"
    guard let start = patch.range(of: target)?.lowerBound else { return "" }
    let tail = patch[start...]
    if let next = tail.dropFirst(target.count).range(of: "\ndiff --git a/")?.lowerBound {
      return String(tail[..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func updateLoadingOverlay() {
    let show = isLoadingTranscript && messages.isEmpty
    loadingSpinner.isHidden = !show
    if show { loadingSpinner.startAnimating() } else { loadingSpinner.stopAnimating() }
    updateEmptyState()
  }

  private var agentDisplayName: String {
    switch (agentBridgeProvider ?? "").lowercased() {
    case "claude": return "Claude"
    case "codex": return "Codex"
    default: return "your agent"
    }
  }

  private func setupEmptyState() {
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.axis = .vertical
    emptyStateView.alignment = .center
    emptyStateView.spacing = 10.0
    emptyStateView.isHidden = true

    emptyStateIcon.translatesAutoresizingMaskIntoConstraints = false
    emptyStateIcon.contentMode = .scaleAspectFit
    emptyStateIcon.image = nil
    emptyStateIcon.isHidden = true

    emptyStateTitle.numberOfLines = 0
    emptyStateTitle.textAlignment = .center
    emptyStateTitle.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
    emptyStateTitle.textColor = appearance.text

    emptyStateSubtitle.numberOfLines = 0
    emptyStateSubtitle.textAlignment = .center
    emptyStateSubtitle.font = UIFont.systemFont(ofSize: 14.5, weight: .regular)
    emptyStateSubtitle.textColor = appearance.textSecondary

    emptyStateView.addArrangedSubview(emptyStateIcon)
    emptyStateView.addArrangedSubview(emptyStateTitle)
    emptyStateView.addArrangedSubview(emptyStateSubtitle)
    emptyStateView.setCustomSpacing(20.0, after: emptyStateIcon)
    emptyStateView.setCustomSpacing(8.0, after: emptyStateTitle)

    NSLayoutConstraint.activate([
      emptyStateIcon.widthAnchor.constraint(equalToConstant: 64),
      emptyStateIcon.heightAnchor.constraint(equalToConstant: 64),
    ])

    tableView.insertSubview(emptyStateView, at: 0)
  }

  private func updateEmptyState() {
    let show = (!isHistoryPicked) || (messages.isEmpty && !isLoadingTranscript && !isEmbeddedInSwiftUI)
    emptyStateView.isHidden = !show
    guard show else { return }
    let repoName = AgentBridgeSelectionStore.selectedRepository()?.name
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let claudeOrange = UIColor(red: 0.83, green: 0.46, blue: 0.30, alpha: 1.0)
    switch (agentBridgeProvider ?? "").lowercased() {
    case "claude":
      let img = VibeAgentKitChatVectorIcon.image(.claudeAgent, color: claudeOrange, size: 48)
      emptyStateIcon.image = img
      emptyStateIcon.isHidden = false
      emptyStateTitle.text = "You've come to absolutely the right place."
      emptyStateSubtitle.isHidden = true
    case "codex":
      let img = VibeAgentKitChatVectorIcon.image(.gptAgent, color: .white, size: 48)?
        .withRenderingMode(.alwaysTemplate)
      emptyStateIcon.image = img
      emptyStateIcon.tintColor = UIColor.label
      emptyStateIcon.isHidden = false
      emptyStateSubtitle.isHidden = false
      if let repoName, !repoName.isEmpty {
        emptyStateTitle.text = "What should we build on \(repoName)?"
      } else {
        emptyStateTitle.text = "What should we build?"
      }
      emptyStateSubtitle.text = "Pick a repo, describe the change, and Codex will work from your computer."
    default:
      emptyStateIcon.isHidden = true
      emptyStateSubtitle.isHidden = false
      let name = agentDisplayName
      emptyStateTitle.text = "Start a new chat with \(name)"
      emptyStateSubtitle.text = "Ask a question or describe a task and \(name) will run it on your computer."
    }
    emptyStateTitle.textColor = appearance.text
    emptyStateSubtitle.textColor = appearance.textSecondary
  }

  // MARK: Scroll helpers

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateScrollInsets()
    updateBottomEdgeFadeFrame()
    // Land at the bottom exactly once, after the first layout pass that actually has
    // rows + resolved insets — so the feed opens pinned to the latest message with no
    // visible jump/settle.
    if !hasPerformedInitialScroll, isHistoryPicked, tableView.numberOfRows(inSection: 0) > 0 {
      hasPerformedInitialScroll = true
      // Never yank a freshly-sent question down: when a push-to-top pin is active this
      // one-shot would otherwise scroll the list to the bottom on the agent's first laid-out
      // frame (the "push-to-top sometimes jumps back to bottom on agent start" bug). Consume
      // the one-shot but hold the pin.
      if pushToTopUserId == nil {
        // Double pass: the first scroll positions against ESTIMATED self-sizing heights;
        // materializing the real cells corrects contentSize, so scroll once more in the
        // same (animation-free) pass. Otherwise the feed visibly settles a frame later —
        // the "starts at the wrong place, then flicks to the bottom" open.
        UIView.performWithoutAnimation {
          scrollToBottom(animated: false)
          tableView.layoutIfNeeded()
          scrollToBottom(animated: false)
        }
      }
    }
    // Keep the pinned question rock-steady across self-sizing settles / row inserts.
    reassertPinnedOffsetIfNeeded()
  }

  private func setupJumpToBottomButton() {
    jumpToBottomButton.translatesAutoresizingMaskIntoConstraints = false
    jumpToBottomButton.alpha = 0.0
    jumpToBottomButton.isHidden = true
    jumpToBottomButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
    jumpToBottomButton.accessibilityLabel = "Jump to latest"
    jumpToBottomButton.addTarget(self, action: #selector(jumpToBottomTapped), for: .touchUpInside)
    // Below the composer in z-order so the pill always wins touches near the edge.
    view.insertSubview(jumpToBottomButton, belowSubview: composerView)
    let size: CGFloat = 38.0
    let bottom = jumpToBottomButton.bottomAnchor.constraint(
      equalTo: composerView.topAnchor, constant: -10.0)
    jumpToBottomBottomConstraint = bottom
    NSLayoutConstraint.activate([
      jumpToBottomButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),
      jumpToBottomButton.widthAnchor.constraint(equalToConstant: size),
      jumpToBottomButton.heightAnchor.constraint(equalToConstant: size),
      bottom,
    ])
    updateJumpButtonAppearance()
  }

  private func updateJumpButtonAppearance() {
    jumpToBottomButton.backgroundColor = appearance.surfaceElevated
    jumpToBottomButton.tintColor = appearance.text
    jumpToBottomButton.layer.cornerRadius = 19.0
    jumpToBottomButton.layer.cornerCurve = .continuous
    jumpToBottomButton.layer.borderWidth = 0.5
    jumpToBottomButton.layer.borderColor =
      vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.22 : 0.16).cgColor
    jumpToBottomButton.layer.shadowColor = UIColor.black.cgColor
    jumpToBottomButton.layer.shadowOpacity = appearance.isDark ? 0.4 : 0.14
    jumpToBottomButton.layer.shadowRadius = 8.0
    jumpToBottomButton.layer.shadowOffset = CGSize(width: 0, height: 3)
    jumpToBottomButton.setImage(
      UIImage(
        systemName: "chevron.down",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
      for: .normal)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    setJumpButtonVisible(!isNearBottom())
    // The user physically grabbed the list while a question was pinned — they own the
    // scroll for the rest of the turn (stop re-asserting the pinned offset).
    if pushToTopUserId != nil, scrollView.isTracking || scrollView.isDragging {
      pushToTopDetached = true
    }
  }

  private func setJumpButtonVisible(_ visible: Bool) {
    let shouldShow = visible && isHistoryPicked && tableView.numberOfRows(inSection: 0) > 0
    guard shouldShow != jumpButtonVisible else { return }
    jumpButtonVisible = shouldShow
    if shouldShow { jumpToBottomButton.isHidden = false }
    UIView.animate(
      withDuration: 0.22,
      delay: 0,
      usingSpringWithDamping: 0.82,
      initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.jumpToBottomButton.alpha = shouldShow ? 1.0 : 0.0
      self.jumpToBottomButton.transform =
        shouldShow ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
    } completion: { _ in
      if !shouldShow, self.jumpToBottomButton.alpha <= 0.01 {
        self.jumpToBottomButton.isHidden = true
      }
    }
  }

  private func setupEditToast() {
    editToastBlur.translatesAutoresizingMaskIntoConstraints = false
    editToastBlur.alpha = 0.0
    editToastBlur.isHidden = true
    editToastBlur.clipsToBounds = true
    editToastBlur.layer.cornerRadius = 16.0
    editToastBlur.layer.cornerCurve = .continuous
    editToastBlur.layer.borderWidth = 0.6
    view.addSubview(editToastBlur)

    editToastIcon.translatesAutoresizingMaskIntoConstraints = false
    editToastIcon.contentMode = .scaleAspectFit
    editToastIcon.image = UIImage(systemName: "doc.text.fill")?.withRenderingMode(.alwaysTemplate)
    editToastBlur.contentView.addSubview(editToastIcon)

    editToastLabel.translatesAutoresizingMaskIntoConstraints = false
    editToastLabel.numberOfLines = 1
    editToastLabel.lineBreakMode = .byTruncatingMiddle
    editToastLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    editToastBlur.contentView.addSubview(editToastLabel)

    NSLayoutConstraint.activate([
      editToastIcon.leadingAnchor.constraint(
        equalTo: editToastBlur.contentView.leadingAnchor, constant: 12.0),
      editToastIcon.centerYAnchor.constraint(equalTo: editToastBlur.contentView.centerYAnchor),
      editToastIcon.widthAnchor.constraint(equalToConstant: 14.0),
      editToastIcon.heightAnchor.constraint(equalToConstant: 14.0),
      editToastLabel.leadingAnchor.constraint(equalTo: editToastIcon.trailingAnchor, constant: 7.0),
      editToastLabel.trailingAnchor.constraint(
        equalTo: editToastBlur.contentView.trailingAnchor, constant: -12.0),
      editToastLabel.topAnchor.constraint(equalTo: editToastBlur.contentView.topAnchor, constant: 7.0),
      editToastLabel.bottomAnchor.constraint(
        equalTo: editToastBlur.contentView.bottomAnchor, constant: -7.0),
    ])
    updateEditToastAppearance()
    updateEditToast()
  }

  private func updateEditToastAppearance() {
    editToastIcon.tintColor = vibeAgentKitColorWithAlpha(appearance.text, 0.82)
    editToastLabel.textColor = vibeAgentKitColorWithAlpha(appearance.text, 0.88)
    editToastBlur.contentView.backgroundColor =
      (appearance.isDark ? UIColor.white : UIColor.black)
      .withAlphaComponent(appearance.isDark ? 0.055 : 0.045)
    editToastBlur.layer.borderColor =
      vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.18 : 0.14).cgColor
  }

  /// A short confirmation pill above the composer — replaces the old (unbounded-height,
  /// "covers the screen" on a long result) command overlay for `/usage` and `/plan`.
  private func setupInfoToast() {
    infoToastBlur.translatesAutoresizingMaskIntoConstraints = false
    infoToastBlur.alpha = 0.0
    infoToastBlur.isHidden = true
    infoToastBlur.clipsToBounds = true
    infoToastBlur.layer.cornerRadius = 16.0
    infoToastBlur.layer.cornerCurve = .continuous
    infoToastBlur.layer.borderWidth = 0.6
    view.addSubview(infoToastBlur)

    infoToastIcon.translatesAutoresizingMaskIntoConstraints = false
    infoToastIcon.contentMode = .scaleAspectFit
    infoToastIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)
    infoToastBlur.contentView.addSubview(infoToastIcon)

    infoToastLabel.translatesAutoresizingMaskIntoConstraints = false
    infoToastLabel.numberOfLines = 1
    infoToastLabel.lineBreakMode = .byTruncatingTail
    infoToastLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    infoToastBlur.contentView.addSubview(infoToastLabel)

    NSLayoutConstraint.activate([
      infoToastBlur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      infoToastBlur.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16.0),
      infoToastBlur.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16.0),
      infoToastBlur.bottomAnchor.constraint(equalTo: composerView.topAnchor, constant: -8.0),
      infoToastIcon.leadingAnchor.constraint(equalTo: infoToastBlur.contentView.leadingAnchor, constant: 12.0),
      infoToastIcon.centerYAnchor.constraint(equalTo: infoToastBlur.contentView.centerYAnchor),
      infoToastIcon.widthAnchor.constraint(equalToConstant: 14.0),
      infoToastIcon.heightAnchor.constraint(equalToConstant: 14.0),
      infoToastLabel.leadingAnchor.constraint(equalTo: infoToastIcon.trailingAnchor, constant: 7.0),
      infoToastLabel.trailingAnchor.constraint(equalTo: infoToastBlur.contentView.trailingAnchor, constant: -12.0),
      infoToastLabel.topAnchor.constraint(equalTo: infoToastBlur.contentView.topAnchor, constant: 7.0),
      infoToastLabel.bottomAnchor.constraint(equalTo: infoToastBlur.contentView.bottomAnchor, constant: -7.0),
    ])
    updateInfoToastAppearance()
  }

  private func updateInfoToastAppearance() {
    infoToastIcon.tintColor = vibeAgentKitColorWithAlpha(appearance.text, 0.82)
    infoToastLabel.textColor = vibeAgentKitColorWithAlpha(appearance.text, 0.88)
    infoToastBlur.contentView.backgroundColor =
      (appearance.isDark ? UIColor.white : UIColor.black)
      .withAlphaComponent(appearance.isDark ? 0.055 : 0.045)
    infoToastBlur.layer.borderColor =
      vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.18 : 0.14).cgColor
  }

  private func showInfoToast(title: String, systemImage: String) {
    infoToastIcon.image = UIImage(systemName: systemImage)
    infoToastLabel.text = title
    infoToastBlur.isHidden = false
    UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.infoToastBlur.alpha = 1.0
    }
    infoToastHideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.hideInfoToast() }
    infoToastHideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
  }

  private func hideInfoToast() {
    infoToastHideWork?.cancel()
    infoToastHideWork = nil
    guard !infoToastBlur.isHidden else { return }
    UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.infoToastBlur.alpha = 0.0
    } completion: { _ in
      if self.infoToastBlur.alpha <= 0.01 { self.infoToastBlur.isHidden = true }
    }
  }

  private func setupUsageBanner() {
    usageBannerView.translatesAutoresizingMaskIntoConstraints = false
    usageBannerView.isHidden = true
    usageBannerView.alpha = 0.0
    usageBannerView.isUserInteractionEnabled = false
    usageBannerView.applyTheme(
      textColor: appearance.text,
      surfaceColor: appearance.surfaceElevated,
      isDark: appearance.isDark
    )
    view.addSubview(usageBannerView)
  }

  private func setupCommandOverlay() {
    commandOverlayView.translatesAutoresizingMaskIntoConstraints = false
    commandOverlayView.isHidden = true
    commandOverlayView.alpha = 0.0
    commandOverlayView.applyAppearance(appearance)
    commandOverlayView.onClose = { [weak self] in self?.hideCommandOverlay() }
    view.addSubview(commandOverlayView)
  }

  /// Show real bridge output (from a `vibe-bridge` result) in the glass overlay
  /// instead of letting it land as a chat bubble.
  /// Extracts the command name from a `vibe-bridge` result's display string, e.g.
  /// "vibe-bridge /usage" → "usage".
  private func bridgeCommandName(_ msg: VibeAgentKitChatMessage) -> String {
    let display = msg.runtime?.command?.display ?? ""
    return display
      .components(separatedBy: " ")
      .first(where: { $0.hasPrefix("/") })
      .map { String($0.dropFirst()).lowercased() }
      ?? ""
  }

  private func showBridgeCommandResult(_ msg: VibeAgentKitChatMessage) {
    guard isViewLoaded, !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let rawName = bridgeCommandName(msg)
    let name = rawName.isEmpty ? "Command" : rawName
    let title = name.prefix(1).uppercased() + String(name.dropFirst())
    commandOverlayView.configure(title: title, body: msg.text)
    showCommandOverlay()
  }

  private func handleComposerCommand(_ command: String) {
    let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return }
    // Plan mode already has two persistent, always-visible cues (the blue slash icon +
    // the blue permission icon via `refreshModePill`) — a toast confirms the switch
    // without popping a local panel that had nothing but stale "reasoning controls" copy.
    if normalized == "/plan" || normalized == "plan" {
      showInfoToast(title: "Plan mode — proposals only, no edits", systemImage: AgentBridgeWorkMode.plan.icon)
      return
    }
    let content: (title: String, body: String)
    switch normalized {
    case "/usage", "usage":
      content = ("Usage", usageCommandBody())
    case "/status", "status":
      content = ("Status", statusCommandBody())
    case "/commands", "commands":
      content = ("Commands", commandsCommandBody())
    case "/skills", "skills":
      content = ("Skills", skillsCommandBody())
    case "/reasoning", "reasoning", "/thinking", "thinking":
      content = ("Reasoning", reasoningCommandBody())
    case "/compact", "compact":
      content = ("Compact", "Compact is available as a bridge command. It is shown here instead of being inserted into chat; run a compact task from the provider CLI when the bridge reports support.")
    default:
      content = ("Command", "No local panel is available for \(command).")
    }
    commandOverlayView.configure(title: content.title, body: content.body)
    showCommandOverlay()
  }

  private func showCommandOverlay() {
    view.bringSubviewToFront(commandOverlayView)
    if commandOverlayView.isHidden {
      commandOverlayView.isHidden = false
      commandOverlayView.transform = CGAffineTransform(translationX: 0, y: 10)
    }
    UIView.animate(
      withDuration: 0.22,
      delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.commandOverlayView.alpha = 1.0
      self.commandOverlayView.transform = .identity
    }
  }

  private func hideCommandOverlay() {
    UIView.animate(
      withDuration: 0.16,
      delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.commandOverlayView.alpha = 0.0
      self.commandOverlayView.transform = CGAffineTransform(translationX: 0, y: 8)
    } completion: { _ in
      if self.commandOverlayView.alpha <= 0.01 {
        self.commandOverlayView.isHidden = true
      }
    }
  }

  private func latestRuntimeSummary() -> ChatListRow.AgentRuntimeSummary? {
    messages.reversed().compactMap { $0.runtime }.first
  }

  /// Feed the `/` palette the slash + CLI commands the connected provider reports
  /// (from the latest runtime metadata), so it lists everything the real CLI exposes.
  private func updateComposerCommandCatalog() {
    let runtime = latestRuntimeSummary()
    composerView.setProviderCommands(
      slash: runtime?.slashCommands ?? [],
      cli: runtime?.cliCommands ?? []
    )
  }

  private func usageCommandBody() -> String {
    guard let runtime = latestRuntimeSummary(), let usage = runtime.usage else {
      return "No usage has been recorded for this chat yet. Run one agent task first."
    }
    let used = agentUsageTokens(usage)
    let limit = agentUsageLimit(provider: runtime.provider ?? agentBridgeProvider, model: runtime.model)
    var parts: [String] = [
      "\(Self.compactTokenCount(used)) / \(Self.compactTokenCount(limit)) tokens"
    ]
    if let input = usage.inputTokens { parts.append("input \(Self.compactTokenCount(input))") }
    if let output = usage.outputTokens { parts.append("output \(Self.compactTokenCount(output))") }
    if let reasoning = usage.reasoningOutputTokens {
      parts.append("reasoning \(Self.compactTokenCount(reasoning))")
    }
    if let cost = usage.totalCostUsd, cost > 0 {
      parts.append(String(format: "$%.2f", cost))
    }
    if let duration = usage.durationMs, duration > 0 {
      parts.append("runtime \(Self.compactDuration(ms: duration))")
    }
    return parts.joined(separator: "\n")
  }

  private func statusCommandBody() -> String {
    let runtime = latestRuntimeSummary()
    let provider = (runtime?.provider ?? agentBridgeProvider ?? composerView.provider)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let repo = runtime?.repoName
      ?? AgentBridgeSelectionStore.selectedRepository()?.name
      ?? "No repository selected"
    let cwd = runtime?.cwd ?? AgentBridgeSelectionStore.selectedRepository()?.path ?? "-"
    let model = runtime?.model
      ?? AgentBridgeSelectionStore.selectedModel(provider: provider)
      ?? "Provider default"
    let mode = runtime?.workMode ?? AgentBridgeSelectionStore.selectedWorkMode().rawValue
    let status = runtime?.status ?? (messages.contains { $0.isStreaming } ? "running" : "idle")
    let device = deviceLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    return [
      "\(provider.isEmpty ? agentDisplayName : provider) bridge status: \(status)",
      "repo: \(repo)",
      "cwd: \(cwd)",
      "work mode: \(mode)",
      "model: \(model)",
      "device: \(device?.isEmpty == false ? device! : "not reported")",
      "connection: \(deviceConnected ? "connected" : "reconnecting")",
    ].joined(separator: "\n")
  }

  private func commandsCommandBody() -> String {
    let runtime = latestRuntimeSummary()
    var sections: [String] = []
    let bridgeCommands = ["/usage", "/status", "/commands", "/skills", "/reasoning", "/plan", "/compact"]
    sections.append("Vibe controls\n" + bridgeCommands.joined(separator: "  "))
    if let runtime {
      let providerSlash = runtime.slashCommands.map { $0.hasPrefix("/") ? $0 : "/\($0)" }
      appendCommandSection("Provider slash commands", providerSlash, to: &sections)
      appendCommandSection("Bridge commands", runtime.providerCommands, to: &sections)
      appendCommandSection("CLI commands", runtime.cliCommands, to: &sections)
      appendCommandSection("Tools", runtime.availableTools, to: &sections)
    }
    return sections.joined(separator: "\n\n")
  }

  private func skillsCommandBody() -> String {
    guard let runtime = latestRuntimeSummary() else {
      return "No skills have been reported for this chat yet."
    }
    var sections: [String] = []
    appendCommandSection("Skills", runtime.skills, to: &sections)
    appendCommandSection("Agents", runtime.agents, to: &sections)
    appendCommandSection(
      "MCP servers",
      runtime.mcpServers.map { server in
        if let status = server.status, !status.isEmpty { return "\(server.name) (\(status))" }
        return server.name
      },
      to: &sections
    )
    return sections.isEmpty ? "No skills or MCP servers were reported by the bridge." : sections.joined(separator: "\n\n")
  }

  private func reasoningCommandBody() -> String {
    let provider = agentBridgeProvider ?? composerView.provider
    let options = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
    let effort = AgentBridgeRunOptions.effectiveEffort(
      provider: provider,
      intelligence: options.intelligence,
      speed: options.speed
    )
    let model = options.model ?? latestRuntimeSummary()?.model ?? "Provider default"
    return [
      "model: \(model)",
      "thinking: \(options.intelligence.title)",
      "speed: \(options.speed.title)",
      "effective effort: \(effort)",
    ].joined(separator: "\n")
  }

  private func appendCommandSection(
    _ title: String,
    _ values: [String],
    to sections: inout [String]
  ) {
    let cleaned = values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !cleaned.isEmpty else { return }
    sections.append(title + "\n" + cleaned.prefix(18).joined(separator: "  "))
  }

  private func updateUsageBanner(force: Bool = false) {
    guard isViewLoaded else { return }
    usageBannerView.applyTheme(
      textColor: appearance.text,
      surfaceColor: appearance.surfaceElevated,
      isDark: appearance.isDark
    )

    guard let snapshot = latestUsageBannerSnapshot(), isHistoryPicked, !isLoadingTranscript else {
      setUsageBannerVisible(false, key: nil, force: force)
      return
    }

    let key = "\(snapshot.title)|\(snapshot.body)"
    if force || key != usageBannerKey {
      usageBannerView.configure(
        title: snapshot.title,
        body: snapshot.body,
        systemImage: "gauge.with.dots.needle.bottom.50percent",
        animateIcon: usageBannerKey != nil
      )
    }
    setUsageBannerVisible(true, key: key, force: force)
  }

  private func setUsageBannerVisible(_ visible: Bool, key: String?, force: Bool) {
    usageBannerKey = key
    guard force || visible != usageBannerVisible else { return }
    usageBannerVisible = visible
    updateScrollInsets()
    if visible {
      usageBannerView.isHidden = false
      view.bringSubviewToFront(usageBannerView)
      UIView.animate(
        withDuration: 0.18,
        delay: 0.0,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        self.usageBannerView.alpha = 1.0
      }
    } else {
      UIView.animate(
        withDuration: 0.16,
        delay: 0.0,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        self.usageBannerView.alpha = 0.0
      } completion: { _ in
        if self.usageBannerView.alpha <= 0.01 {
          self.usageBannerView.isHidden = true
        }
      }
    }
  }

  private func latestUsageBannerSnapshot() -> (title: String, body: String)? {
    for message in messages.reversed() {
      guard let runtime = message.runtime, let usage = runtime.usage else { continue }
      let used = agentUsageTokens(usage)
      guard used > 0 else { continue }
      let limit = agentUsageLimit(provider: runtime.provider ?? agentBridgeProvider, model: runtime.model)
      let ratio = Double(used) / Double(limit)
      let commandDisplay = runtime.command?.display?.lowercased() ?? ""
      let isExplicitUsageResult = commandDisplay.contains("/usage")
      guard isExplicitUsageResult || ratio >= 0.72 else { continue }

      let provider = (runtime.provider ?? agentBridgeProvider ?? agentDisplayName)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let providerTitle =
        provider.isEmpty
        ? agentDisplayName
        : provider.prefix(1).uppercased() + String(provider.dropFirst())
      let percent = Int(round(ratio * 100.0))
      var body =
        "\(providerTitle) \(percent)% · \(Self.compactTokenCount(used)) / \(Self.compactTokenCount(limit)) tokens"
      if let cost = usage.totalCostUsd, cost > 0 {
        body += String(format: " · $%.2f", cost)
      }
      let title = ratio >= 0.9 ? "Context nearly full" : "Context usage"
      return (title, body)
    }
    return nil
  }

  private func agentUsageTokens(_ usage: ChatListRow.AgentRuntimeUsage) -> Int {
    max(
      0,
      (usage.inputTokens ?? 0)
        + (usage.outputTokens ?? 0)
        + (usage.reasoningOutputTokens ?? 0)
    )
  }

  private func agentUsageLimit(provider: String?, model: String?) -> Int {
    let providerValue = (provider ?? "").lowercased()
    let modelValue = (model ?? "").lowercased()
    if providerValue == "claude" || modelValue.contains("claude") {
      return 200_000
    }
    return 200_000
  }

  private static func compactTokenCount(_ value: Int) -> String {
    if value >= 1_000_000 {
      return String(format: "%.1fM", Double(value) / 1_000_000.0)
    }
    if value >= 1000 {
      return String(format: "%.0fk", Double(value) / 1000.0)
    }
    return "\(value)"
  }

  private static func compactDuration(ms: Int) -> String {
    let seconds = max(0, ms / 1000)
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    let remaining = seconds % 60
    if minutes < 60 { return "\(minutes)m \(remaining)s" }
    return "\(minutes / 60)h \(minutes % 60)m"
  }

  private func updateEditToast() {
    guard isViewLoaded else { return }
    let summary = editDiffSummary()
    let hasLiveTurn = messages.contains { $0.isStreaming || $0.runtime?.status == "running" }
    let shouldShow = summary != nil && isHistoryPicked && !isLoadingTranscript && !hasLiveTurn
    if let summary {
      editToastLabel.attributedText = summary.attributed
      editToastLabel.accessibilityLabel = summary.plain
    }
    guard editToastBlur.isHidden == shouldShow || abs(editToastBlur.alpha - (shouldShow ? 1.0 : 0.0)) > 0.01 else {
      return
    }
    if shouldShow {
      editToastBlur.isHidden = false
      UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.editToastBlur.alpha = 1.0
      }
    } else {
      UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.editToastBlur.alpha = 0.0
      } completion: { _ in
        if self.editToastBlur.alpha <= 0.01 { self.editToastBlur.isHidden = true }
      }
    }
  }

  // MARK: Subagent (Claude Task tool) surfacing

  private func setupSubagentToast() {
    subagentToastBlur.translatesAutoresizingMaskIntoConstraints = false
    subagentToastBlur.alpha = 0.0
    subagentToastBlur.isHidden = true
    subagentToastBlur.clipsToBounds = true
    subagentToastBlur.layer.cornerRadius = 16.0
    subagentToastBlur.layer.cornerCurve = .continuous
    subagentToastBlur.layer.borderWidth = 0.6
    subagentToastBlur.layer.borderColor =
      vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.18 : 0.14).cgColor
    subagentToastBlur.contentView.backgroundColor =
      (appearance.isDark ? UIColor.white : UIColor.black)
      .withAlphaComponent(appearance.isDark ? 0.055 : 0.045)
    view.addSubview(subagentToastBlur)

    subagentToastLabel.translatesAutoresizingMaskIntoConstraints = false
    subagentToastLabel.numberOfLines = 1
    subagentToastLabel.lineBreakMode = .byTruncatingTail
    subagentToastLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    subagentToastLabel.textColor = vibeAgentKitColorWithAlpha(appearance.text, 0.9)
    subagentToastBlur.contentView.addSubview(subagentToastLabel)

    NSLayoutConstraint.activate([
      subagentToastBlur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      subagentToastBlur.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60.0),
      subagentToastBlur.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.leadingAnchor, constant: 24.0),
      subagentToastBlur.trailingAnchor.constraint(
        lessThanOrEqualTo: view.trailingAnchor, constant: -24.0),
      subagentToastLabel.leadingAnchor.constraint(
        equalTo: subagentToastBlur.contentView.leadingAnchor, constant: 14.0),
      subagentToastLabel.trailingAnchor.constraint(
        equalTo: subagentToastBlur.contentView.trailingAnchor, constant: -12.0),
      subagentToastLabel.topAnchor.constraint(equalTo: subagentToastBlur.contentView.topAnchor, constant: 8.0),
      subagentToastLabel.bottomAnchor.constraint(
        equalTo: subagentToastBlur.contentView.bottomAnchor, constant: -8.0),
    ])
    subagentToastBlur.contentView.isUserInteractionEnabled = true
    subagentToastBlur.contentView.addGestureRecognizer(
      UITapGestureRecognizer(target: self, action: #selector(handleSubagentToastTap)))
  }

  @objc private func handleSubagentToastTap() {
    guard let target = subagentToastTarget else { return }
    hideSubagentToast()
    presentSubagentView(messageId: target.messageId, parentNodeId: target.nodeId)
  }

  /// All running subagents in the current transcript, as (messageId, nodeId, type).
  private func runningSubagents(in msgs: [VibeAgentKitChatMessage])
    -> [(messageId: String, nodeId: String, type: String)]
  {
    var out: [(messageId: String, nodeId: String, type: String)] = []
    for message in msgs {
      for item in message.progressItems {
        guard item.itemType == "task" || (item.subagentType?.isEmpty == false) else { continue }
        let nodeId = item.nodeId ?? item.label
        let running = vibeAgentKitRunningStepStatuses.contains((item.status ?? "").lowercased())
        guard running else { continue }
        out.append((messageId: message.id, nodeId: nodeId, type: item.subagentType ?? ""))
      }
    }
    return out
  }

  private func updateSubagentState(_ newMessages: [VibeAgentKitChatMessage]) {
    guard isViewLoaded else { return }
    // Announce any newly-running subagent once (toast auto-fades; the feed row persists).
    for sub in runningSubagents(in: newMessages) where !toastedSubagentIds.contains(sub.nodeId) {
      toastedSubagentIds.insert(sub.nodeId)
      showSubagentToast(messageId: sub.messageId, nodeId: sub.nodeId, type: sub.type)
    }
    // Keep an open detail view streaming: re-feed it the latest children for its parent.
    if let ref = openSubagentRef, let detail = openSubagentDetail,
      let message = newMessages.first(where: { $0.id == ref.messageId })
    {
      let stillRunning = runningSubagents(in: newMessages).contains { $0.nodeId == ref.nodeId }
      detail.update(
        progressItems: message.subagentChildren[ref.nodeId] ?? [],
        running: stillRunning)
    }
  }

  private func showSubagentToast(messageId: String, nodeId: String, type: String) {
    subagentToastTarget = (messageId: messageId, nodeId: nodeId)
    let flavor = type.trimmingCharacters(in: .whitespacesAndNewlines)
    subagentToastLabel.text = flavor.isEmpty ? "Subagent running" : "Subagent running · \(flavor)"
    subagentToastBlur.isHidden = false
    UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.subagentToastBlur.alpha = 1.0
    }
    subagentToastHideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.hideSubagentToast() }
    subagentToastHideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
  }

  private func hideSubagentToast() {
    subagentToastHideWork?.cancel()
    subagentToastHideWork = nil
    guard !subagentToastBlur.isHidden else { return }
    UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.subagentToastBlur.alpha = 0.0
    } completion: { _ in
      if self.subagentToastBlur.alpha <= 0.01 { self.subagentToastBlur.isHidden = true }
    }
  }

  /// Open the read-only subagent view (no composer) for a parent Task node, seeded with
  /// its current children and kept live by `updateSubagentState`.
  private func presentSubagentView(messageId: String, parentNodeId: String) {
    guard let message = messages.first(where: { $0.id == messageId }) else { return }
    let children = message.subagentChildren[parentNodeId] ?? []
    let type = message.progressItems.first {
      (($0.nodeId ?? $0.label) == parentNodeId) && ($0.subagentType?.isEmpty == false)
    }?.subagentType ?? ""
    let running = runningSubagents(in: messages).contains { $0.nodeId == parentNodeId }
    let detail = VibeAgentSubagentDetailViewController(
      subagentType: type,
      progressItems: children,
      running: running,
      appearance: appearance)
    openSubagentDetail = detail
    openSubagentRef = (messageId: messageId, nodeId: parentNodeId)
    detail.onClose = { [weak self] in
      self?.openSubagentDetail = nil
      self?.openSubagentRef = nil
    }
    detail.modalPresentationStyle = .pageSheet
    if let sheet = detail.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(detail, animated: true)
  }

  /// The whole-history diff at a glance (not a single edited-file detail): how many files
  /// the session changed and the total lines added (green) / removed (red). This is what
  /// the toast above the composer shows when a history is opened.
  private func editDiffSummary() -> (plain: String, attributed: NSAttributedString)? {
    var files = Set<String>()
    var lastFile: String?
    var added = 0
    var removed = 0
    for message in messages {
      for item in message.progressItems {
        let kind = (item.itemType ?? item.tool ?? "").lowercased()
        guard kind == "edit" || kind == "write" else { continue }
        let file = item.fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (file?.isEmpty == false) ? file! : item.label
        let leaf = URL(fileURLWithPath: name).lastPathComponent
        if !leaf.isEmpty {
          files.insert(leaf)
          lastFile = leaf
        }
        let counts = editCounts(label: item.label, patch: item.patch)
        added += counts.added
        removed += counts.removed
      }
    }
    guard !files.isEmpty || added > 0 || removed > 0 else { return nil }

    let fileText = (files.count == 1 ? lastFile : "\(files.count) files")
      ?? "\(files.count) files"
    let font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    let attr = NSMutableAttributedString(
      string: fileText,
      attributes: [
        .foregroundColor: vibeAgentKitColorWithAlpha(appearance.text, 0.9),
        .font: font,
      ])
    if added > 0 {
      attr.append(NSAttributedString(
        string: "  +\(added)",
        attributes: [.foregroundColor: UIColor.systemGreen, .font: font]))
    }
    if removed > 0 {
      attr.append(NSAttributedString(
        string: "  −\(removed)",
        attributes: [.foregroundColor: UIColor.systemRed, .font: font]))
    }
    let plain = "\(fileText) · +\(added) −\(removed)"
    return (plain, attr)
  }

  /// Added/removed line counts for one edit. Prefers the actual patch (count of `+`/`-`
  /// body lines) and falls back to the first `+N` / `-N` tokens in the label. The
  /// deletion token uses a non-digit lookbehind so a `Lines 10-20` range isn't misread
  /// as `-20` removed lines.
  private func editCounts(label: String, patch: String?) -> (added: Int, removed: Int) {
    if let patch, patch.contains("\n") {
      var added = 0
      var removed = 0
      for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
          added += 1
        } else if line.hasPrefix("-"), !line.hasPrefix("---") {
          removed += 1
        }
      }
      if added > 0 || removed > 0 { return (added, removed) }
    }
    return (
      firstIntMatch(in: label, pattern: "\\+(\\d[\\d,]*)"),
      firstIntMatch(in: label, pattern: "(?<![0-9])[−-](\\d[\\d,]*)")
    )
  }

  private func firstIntMatch(in text: String, pattern: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
    let ns = text as NSString
    guard
      let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
      match.numberOfRanges > 1
    else { return 0 }
    let digits = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
    return Int(digits) ?? 0
  }

  private func updateBottomEdgeFade() {
    let bg = appearance.background
    let gradient = CAGradientLayer()
    gradient.colors = [UIColor.clear.cgColor, bg.cgColor]
    gradient.locations = [0.0, 1.0]
    // Replace any existing gradient sublayer.
    bottomEdgeFadeView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    bottomEdgeFadeView.layer.addSublayer(gradient)
    updateBottomEdgeFadeFrame()
  }

  private func updateRepoPickerStyle() {
    var config = UIButton.Configuration.plain()

    let repoName = AgentBridgeSelectionStore.selectedRepository()?.name ?? "Repository"
    config.title = repoName

    config.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    config.imagePlacement = .trailing
    config.imagePadding = 5
    config.baseForegroundColor = appearance.textSecondary
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)

    repoPickerButton.configuration = config
    repoPickerButton.isHidden = (repoPickerMenu == nil) || isHistoryPicked
  }

  private func updateBottomEdgeFadeFrame() {
    guard let gradient = bottomEdgeFadeView.layer.sublayers?.first as? CAGradientLayer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradient.frame = bottomEdgeFadeView.bounds
    CATransaction.commit()
  }

  /// Keep the feed's bottom inset matched to however much of the screen the floating
  /// composer (and, when raised, the keyboard) currently covers, so the last bubble
  /// always clears the pill even though the table extends edge-to-edge beneath it.
  private func updateScrollInsets(force: Bool = false) {
    let covered = max(0, view.bounds.maxY - composerView.frame.minY)
    // The table reaches the screen bottom, so its automatic safe-area inset already
    // covers the home indicator; only add the part above it, plus a small gap.
    let baseBottom = max(12, covered - view.safeAreaInsets.bottom + 8)
    // While a send is pinned to the top, reserve room below so the question can hold near
    // the top with the answer streaming beneath it (ChatGPT / Resolo-style). The reserve is
    // recomputed LIVE here every layout pass (Resolo models it as a `minHeight` floor on the
    // current-turn container, not an imperatively-managed inset) so it shrinks to 0 on its
    // own as the answer fills the viewport — no stale "huge gap" left behind by a relax
    // token that measured a not-yet-grown contentSize.
    pushToTopReserve = computedPushToTopReserve()
    let bottom = max(baseBottom, pushToTopReserve)
    let top = usageBannerVisible ? ChatPinnedBannerView.preferredHeight + 24.0 : 12.0
    guard force || abs(tableView.contentInset.bottom - bottom) > 0.5
      || abs(tableView.contentInset.top - top) > 0.5
    else { return }
    let wasNearBottom = isNearBottom()
    tableView.contentInset.bottom = bottom
    tableView.contentInset.top = top
    tableView.verticalScrollIndicatorInsets.bottom = bottom
    tableView.verticalScrollIndicatorInsets.top = top
    if wasNearBottom, pushToTopUserId == nil, pushToTopReserve <= 0, toggleScrollLockDepth == 0 {
      scrollToBottom(animated: false)
    }
  }

  /// The reserve needed RIGHT NOW so the pinned user message can stay at the top with the
  /// answer streaming below it. Sized so the max scroll offset equals the pinned question's
  /// offset (`contentSize + reserve - bounds == userMinY - paddingTop`), matching the
  /// collection-view agent surface. Returns 0 once the answer fills the available space,
  /// so the gap closes itself (Resolo's self-correcting floor, ported to a UITableView).
  private func computedPushToTopReserve() -> CGFloat {
    guard let id = pushToTopUserId,
      let idx = tableMessages.firstIndex(where: { $0.id == id })
    else { return 0 }
    let rect = tableView.rectForRow(at: IndexPath(row: idx, section: 0))
    guard rect.height > 0 else { return 0 }
    let topInset = tableView.adjustedContentInset.top
    let viewport = max(0, tableView.bounds.height - topInset)
    let contentBelow = max(0, tableView.contentSize.height - rect.minY)
    return max(0, viewport - contentBelow)
  }

  // MARK: Push-to-top send (ChatGPT-style)

  /// The user message currently pinned near the top while its answer streams below.
  private var pushToTopUserId: String?
  /// Extra bottom inset reserved so the pinned question can rise to the top; it shrinks
  /// toward zero as the answer fills the space below.
  private var pushToTopReserve: CGFloat = 0
  /// The user grabbed the list after the pin — stop re-asserting the pinned offset so
  /// they can scroll freely for the rest of the turn.
  private var pushToTopDetached = false
  /// While the animated pin scroll is in flight, the per-layout re-assert must not
  /// snap the offset out from under the spring.
  private var pinAnimationDeadline: Date?

  /// Hold the pinned question exactly at its target offset across the passes that used
  /// to nudge it (self-sizing estimates resolving, the answer row inserting below, inset
  /// changes) — the "lands, then hops ~10px" bug. Never fights the user: bails while
  /// they touch/fling the list or once they've detached, and stays quiet during the
  /// pin's own spring animation and inline toggle updates.
  private func reassertPinnedOffsetIfNeeded() {
    guard let id = pushToTopUserId, !pushToTopDetached, toggleScrollLockDepth == 0,
      !tableView.isTracking, !tableView.isDragging, !tableView.isDecelerating,
      let idx = tableMessages.firstIndex(where: { $0.id == id })
    else { return }
    if let deadline = pinAnimationDeadline {
      if Date() < deadline { return }
      pinAnimationDeadline = nil
    }
    let rect = tableView.rectForRow(at: IndexPath(row: idx, section: 0))
    guard rect.height > 0 else { return }
    let topInset = tableView.adjustedContentInset.top
    let targetY = pixelAlignedValue(max(-topInset, rect.minY - topInset))
    if abs(tableView.contentOffset.y - targetY) > 0.5 {
      tableView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
    }
  }

  /// Pin a freshly-sent user message to the top. The room below is reserved passively by
  /// `updateScrollInsets`/`computedPushToTopReserve` (recomputed every layout pass, so it
  /// shrinks to 0 as the answer fills it — Resolo's self-correcting floor). Here we only
  /// force one inset update (so the reserve exists before we move) and scroll the question
  /// to the top; from then on the content above it is fixed, so it simply holds its place.
  private func pinUserMessageToTop(id: String, animated: Bool) {
    guard let idx = tableMessages.firstIndex(where: { $0.id == id }) else { return }
    pushToTopUserId = id
    pushToTopDetached = false
    pinAnimationDeadline = animated ? Date().addingTimeInterval(0.55) : nil
    tableView.layoutIfNeeded()
    updateScrollInsets(force: true)
    tableView.layoutIfNeeded()
    let rect = tableView.rectForRow(at: IndexPath(row: idx, section: 0))
    let topInset = tableView.adjustedContentInset.top
    let targetY = pixelAlignedValue(max(-topInset, rect.minY - topInset))
    setTableContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
  }

  private func setTableContentOffset(_ offset: CGPoint, animated: Bool) {
    guard animated else {
      tableView.setContentOffset(offset, animated: false)
      return
    }
    UIView.animate(
      withDuration: 0.42,
      delay: 0,
      usingSpringWithDamping: 0.82,
      initialSpringVelocity: 0.4,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.tableView.setContentOffset(offset, animated: false)
    }
  }

  private func pixelAlignedValue(_ value: CGFloat) -> CGFloat {
    let scale =
      view.window?.windowScene?.screen.scale ?? view.window?.screen.scale ?? traitCollection.displayScale
    guard scale > 0 else { return value }
    return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
  }

  private func isNearBottom() -> Bool {
    let offsetY = tableView.contentOffset.y
    let bottom = tableView.contentSize.height - tableView.bounds.height + tableView.contentInset.bottom
    return offsetY >= bottom - 120
  }

  private func scrollToBottom(animated: Bool) {
    let rows = tableView.numberOfRows(inSection: 0)
    guard rows > 0 else { return }
    let last = IndexPath(row: rows - 1, section: 0)
    tableView.scrollToRow(at: last, at: .bottom, animated: animated)
  }
}

/// A small custom progress indicator — a single rotating arc — used as the centered
/// loader while a transcript loads (rather than the system activity indicator or a
/// fake "Loading…" message bubble).
final class VibeAgentCommandOverlayView: UIView {
  private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()
  private let closeButton = UIButton(type: .system)
  private var appearance: VibeAgentKitChatAppearance = .fallback

  var onClose: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) { return nil }

  func applyAppearance(_ appearance: VibeAgentKitChatAppearance) {
    self.appearance = appearance
    blurView.contentView.backgroundColor = vibeAgentKitColorWithAlpha(
      appearance.isDark ? UIColor.white : UIColor.black,
      appearance.isDark ? 0.065 : 0.045
    )
    layer.borderColor = vibeAgentKitColorWithAlpha(
      appearance.textSecondary,
      appearance.isDark ? 0.2 : 0.16
    ).cgColor
    titleLabel.textColor = appearance.text
    bodyLabel.textColor = vibeAgentKitColorWithAlpha(appearance.text, 0.78)
    closeButton.tintColor = vibeAgentKitColorWithAlpha(appearance.text, 0.78)
  }

  func configure(title: String, body: String) {
    titleLabel.text = title
    bodyLabel.text = body
    setNeedsLayout()
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerRadius = 18.0
    layer.cornerCurve = .continuous
    layer.borderWidth = 0.7

    blurView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blurView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
    titleLabel.numberOfLines = 1
    blurView.contentView.addSubview(titleLabel)

    bodyLabel.translatesAutoresizingMaskIntoConstraints = false
    bodyLabel.font = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    bodyLabel.numberOfLines = 0
    blurView.contentView.addSubview(bodyLabel)

    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.setImage(
      UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)),
      for: .normal
    )
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    blurView.contentView.addSubview(closeButton)

    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

      titleLabel.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 14.0),
      titleLabel.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 16.0),
      titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8.0),

      closeButton.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 8.0),
      closeButton.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -8.0),
      closeButton.widthAnchor.constraint(equalToConstant: 34.0),
      closeButton.heightAnchor.constraint(equalToConstant: 34.0),

      bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10.0),
      bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      bodyLabel.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -16.0),
      bodyLabel.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -14.0),
    ])

    applyAppearance(.fallback)
  }

  @objc private func closeTapped() {
    onClose?()
  }
}

private struct VibeAgentImagePreview: View {
  let image: UIImage
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Color.black.ignoresSafeArea()
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(.ultraThinMaterial, in: Circle())
      }
      .padding(.top, 18)
      .padding(.trailing, 18)
    }
  }
}

private final class VibeAgentArcSpinner: UIView {
  private let arcLayer = CAShapeLayer()

  var color: UIColor = .secondaryLabel {
    didSet { arcLayer.strokeColor = color.cgColor }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    arcLayer.fillColor = UIColor.clear.cgColor
    arcLayer.strokeColor = color.cgColor
    arcLayer.lineCap = .round
    arcLayer.lineWidth = 1.5
    layer.addSublayer(arcLayer)
  }

  required init?(coder: NSCoder) { return nil }

  override var intrinsicContentSize: CGSize { CGSize(width: 30, height: 30) }

  public override func layoutSubviews() {
    super.layoutSubviews()
    arcLayer.frame = bounds
    let inset = arcLayer.lineWidth / 2
    let rect = bounds.insetBy(dx: inset, dy: inset)
    arcLayer.path = UIBezierPath(
      arcCenter: CGPoint(x: rect.midX, y: rect.midY),
      radius: max(0, rect.width / 2),
      startAngle: -.pi / 2,
      endAngle: .pi * 1.15,
      clockwise: true
    ).cgPath
  }

  func startAnimating() {
    guard layer.animation(forKey: "spin") == nil else { return }
    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0
    spin.toValue = 2 * Double.pi
    spin.duration = 0.85
    spin.repeatCount = .infinity
    spin.isRemovedOnCompletion = false
    layer.add(spin, forKey: "spin")
  }

  func stopAnimating() {
    layer.removeAnimation(forKey: "spin")
  }
}

/// The circular agent avatar shown in the header (profile button). Renders the SAME
/// avatar the main chat view uses: the gradient keyed by the conversation's title /
/// peer / chat id (`ChatProfileAppearanceStore.avatarColors`), an initial glyph on top,
/// and — when the conversation has an uploaded picture — the fetched image resolved
/// through the shared `ChatAvatarURLResolver` + `ChatAvatarImageStore` (so it matches
/// the main view instead of a generic SF person symbol).
final class VibeAgentHeaderAvatarView: UIControl {
  private let gradientLayer = CAGradientLayer()
  private let initialLabel = UILabel()
  private let imageView = UIImageView()
  private var loadToken = 0
  // Matches the UINavigationBar button wrapper's 36pt min-width slot so the avatar fills
  // it exactly (no constraint fight); the size constraints below are also sub-required as
  // a belt-and-suspenders against the wrapper ever pinning a different width.
  private let diameter: CGFloat = 36

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    clipsToBounds = true
    layer.cornerCurve = .continuous
    gradientLayer.startPoint = CGPoint(x: 0, y: 0)
    gradientLayer.endPoint = CGPoint(x: 1, y: 1)
    layer.addSublayer(gradientLayer)

    initialLabel.textAlignment = .center
    initialLabel.textColor = .white
    initialLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    initialLabel.isUserInteractionEnabled = false
    addSubview(initialLabel)

    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.isHidden = true
    imageView.isUserInteractionEnabled = false
    addSubview(imageView)

    let avatarWidth = widthAnchor.constraint(equalToConstant: diameter)
    let avatarHeight = heightAnchor.constraint(equalToConstant: diameter)
    avatarWidth.priority = .required
    avatarHeight.priority = .required
    NSLayoutConstraint.activate([avatarWidth, avatarHeight])
  }

  required init?(coder: NSCoder) { return nil }

  override var intrinsicContentSize: CGSize { CGSize(width: diameter, height: diameter) }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = diameter / 2
    imageView.layer.cornerRadius = diameter / 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradientLayer.frame = bounds
    CATransaction.commit()
    initialLabel.frame = bounds
    imageView.frame = bounds
  }

  func configure(title: String?, peerUserId: String?, chatId: String?, avatarURI: String?, isDark: Bool) {
    let colors = ChatProfileAppearanceStore.avatarColors(
      title: title, peerUserId: peerUserId, chatId: chatId)
    gradientLayer.colors = [colors.0.cgColor, colors.1.cgColor]
    let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    initialLabel.text = trimmed.isEmpty ? "" : String(trimmed.prefix(1)).uppercased()

    // Invalidate any in-flight load, then resolve + fetch the picture exactly as the
    // main view does. No picture → the gradient + initial stand in (also the main view's
    // behavior), so the two surfaces always agree.
    loadToken &+= 1
    let token = loadToken
    imageView.image = nil
    imageView.isHidden = true
    let raw = (avatarURI ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = ChatAvatarURLResolver.resolve(
      rawAvatar: raw,
      peerUserId: peerUserId,
      chatId: chatId,
      preferPushAvatar: (peerUserId?.isEmpty == false)
    ) ?? (raw.isEmpty ? "" : raw)
    guard !resolved.isEmpty else {
      imageView.isHidden = true
      return
    }
    if let cached = ChatAvatarImageStore.cached(for: resolved) {
      imageView.image = cached
      imageView.isHidden = false
      return
    }
    imageView.isHidden = true
    Task { [weak self] in
      let image = await ChatAvatarImageStore.load(from: resolved)
      await MainActor.run {
        guard let self, self.loadToken == token, let image else { return }
        self.imageView.image = image
        self.imageView.isHidden = false
      }
    }
  }
}

/// The agent conversation input: one glass pill that is a single compact line at
/// rest (placeholder + mic/send only) and grows into two rows — the text on top,
/// full width, and a plus/slash/permission row underneath — once it's focused or
/// holds a draft. `self` is a transparent container that extends to the very
/// bottom of the screen (ignoring the safe-area inset) so there is no edge/strip
/// below the input; the pill row is inset above the home indicator.
///
/// Each control in the bottom row is independent: tapping it opens its own native
/// `UIMenu` (or, for "+", delegates to the host's image picker) and never resizes
/// the pill itself — only focus/text/attachment state does that. The public API is
/// unchanged from the previous implementation so both hosts (the standalone agent
/// runtime view and the embedded Claude/Codex DM composer) adopt it with no
/// integration changes.
/// One entry in the composer's `/` command palette. `kind` decides routing when the
/// command is run: `.runOption` is applied locally (it configures the next run);
/// every other kind is SENT to the bridge, which executes it for real — bridge info
/// commands (`/usage`, `/status`, `/doctor`, …) return live data, and provider/CLI
/// slash commands pass through to the actual CLI. No more local mock panels.
struct VibeAgentSlashCommand {
  enum Kind { case bridge, runOption, providerSlash, cli }
  let name: String           // no leading slash
  let subtitle: String
  let kind: Kind
  let takesArgs: Bool
  var display: String { "/\(name)" }
}

public final class VibeComposerView: UIView, UITextViewDelegate {
  var onSend: ((String, AgentBridgeRunOptions) -> Void)? {
    didSet { updateSendState() }
  }
  /// Tapped the trailing control while a task is running — the host cancels the live
  /// bridge run (SIGTERM). Distinct from `onSend` so an active turn can never send.
  var onStop: (() -> Void)?
  var onHeightChanged: ((CGFloat) -> Void)?
  /// Tapped the "+" — the controller presents an image picker and stages the result
  /// via `addAttachment(blob:)`. The composer can't present, so it delegates up.
  var onAttach: (() -> Void)?
  /// Agent bridge command shortcuts (`/usage`, `/compact`, ...). These are local
  /// control panels in the agent surface, not chat messages.
  var onCommand: ((String) -> Void)? {
    didSet { updateCommandMenu() }
  }
  /// Encrypted image blobs staged to ride along with the next send.
  private var pendingAttachmentBlobs: [String] = []
  var placeholder: String = "Ask Codex" {
    didSet { placeholderLabel.text = placeholder }
  }
  /// Drives which run options are read at send time (Claude vs Codex ladders).
  var provider: String = "codex" {
    didSet {
      updateCommandMenu()
      // Seed the `/` palette with this provider's full catalog right away so it's
      // complete from the first `/`; a later runtime summary swaps in the real list.
      if provider != oldValue || providerSlashCommands.isEmpty {
        setProviderCommands(slash: [], cli: [])
      }
    }
  }

  // MARK: Subviews — one glass surface that grows in height on focus.
  private let pillGlass = UIVisualEffectView(effect: nil)
  private let pillContainer = UIView()
  private let plusButton = UIButton(type: .system)
  private let slashButton = UIButton(type: .system)
  private let permissionButton = UIButton(type: .system)
  private let textView = UITextView()
  private let placeholderLabel = UILabel()
  private let sendButton = UIButton(type: .system)
  private let micButton = UIButton(type: .system)

  // `/` command list — a native UIMenu on `slashButton` (same pattern as the
  // permission menu on `permissionButton`): it floats above the composer and never
  // resizes it. Replaces an older in-house drop-up table that used to grow the
  // whole pill upward whenever it was opened.
  private var providerSlashCommands: [VibeAgentSlashCommand] = []
  private var providerCliCommands: [VibeAgentSlashCommand] = []

  /// Bridge + run-option commands always offered, independent of what the CLI reports.
  private static let defaultCommands: [VibeAgentSlashCommand] = [
    .init(name: "usage", subtitle: "Subscription limits + this chat's tokens", kind: .bridge, takesArgs: false),
    .init(name: "status", subtitle: "Account, model, and remaining usage", kind: .bridge, takesArgs: false),
    .init(name: "commands", subtitle: "List every available command", kind: .bridge, takesArgs: false),
    .init(name: "skills", subtitle: "Skills, agents, MCP servers, and tools", kind: .bridge, takesArgs: false),
    .init(name: "doctor", subtitle: "Run the CLI health check", kind: .bridge, takesArgs: false),
    .init(name: "compact", subtitle: "Start the next run without resume state", kind: .bridge, takesArgs: false),
    .init(name: "model", subtitle: "Show or set the model for this chat", kind: .bridge, takesArgs: true),
    .init(name: "plan", subtitle: "Plan only — analyze without editing", kind: .runOption, takesArgs: false),
    .init(name: "reasoning", subtitle: "Thinking / speed for this chat", kind: .runOption, takesArgs: false),
  ]

  // One-line descriptions so palette rows show what each command does (not "mock").
  // Mirrors the bridge catalogs; unknown/custom commands fall back to a generic label.
  private static let commandDescriptions: [String: String] = [
    "usage": "Subscription limits + this chat's tokens",
    "status": "Account, model, and remaining usage",
    "commands": "List every available command",
    "skills": "Skills, agents, MCP servers, and tools",
    "help": "List every available command",
    "doctor": "Run the CLI health check",
    "compact": "Free up context / drop resume state",
    "model": "Show or set the model",
    "plan": "Plan only — analyze without editing",
    "reasoning": "Thinking / speed for this chat",
    // Claude skills / workflows / built-ins (run as an agent turn)
    "code-review": "Review the diff for bugs and cleanups",
    "simplify": "Cleanup-only review; apply fixes",
    "security-review": "Scan changes for security issues",
    "review": "Review a GitHub pull request",
    "batch": "Split a large change into parallel units",
    "deep-research": "Web research into a cited report",
    "claude-api": "Load Claude API reference",
    "debug": "Troubleshoot via the debug log",
    "run": "Launch and drive your app",
    "verify": "Build, run, and observe a change",
    "loop": "Run a prompt repeatedly",
    "schedule": "Create or run a cloud routine",
    "team-onboarding": "Generate a team onboarding guide",
    "fewer-permission-prompts": "Add a read-only allowlist",
    "init": "Generate a project guide",
    "insights": "Analyze your recent sessions",
    "goal": "Keep working until a goal is met",
    "context": "Show context-window usage",
    "config": "View or set a setting",
    "clear": "Start a fresh conversation",
    "usage-credits": "Configure extra usage credits",
    // Codex-specific
    "approvals": "Set what Codex can do without asking",
    "diff": "Show the working-tree git diff",
    "new": "Start a new conversation",
    "agent": "Switch the active agent thread",
    "apps": "Browse connectors",
    "plugins": "Browse plugins",
    "mcp": "List configured MCP tools",
    "mention": "Attach a file",
    "fork": "Fork into a new thread",
    "resume": "Resume a saved conversation",
    "memories": "Configure memory",
    "fast": "Toggle the Fast tier",
    "personality": "Choose a response style",
    "logout": "Sign out",
    // CLI subcommands
    "exec": "Run non-interactively",
    "apply": "Apply the latest diff to your tree",
    "login": "Sign in",
    "cloud": "Browse Codex Cloud tasks",
    "sandbox": "Run inside the sandbox",
    "update": "Update the CLI",
    "plugin": "Manage plugins",
    "agents": "Manage subagents",
  ]

  // Codex slash commands are TUI-only (`codex exec` can't run them) — flag them so the
  // palette tells the user, and the bridge answers with a "use the desktop app" note.
  private static let codexDesktopOnly: Set<String> = [
    "review", "approvals", "diff", "new", "clear", "init", "skills", "agent", "apps",
    "plugins", "mcp", "mention", "fork", "resume", "memories", "goal", "personality", "logout",
  ]

  // Seed the palette before the first run delivers the CLI's real catalog. Claude's live
  // list (from each run's init event) replaces this once a turn completes.
  private static let claudeFallbackSlash = [
    "code-review", "simplify", "security-review", "review", "batch", "deep-research",
    "claude-api", "debug", "run", "verify", "loop", "schedule", "team-onboarding",
    "fewer-permission-prompts", "init", "insights", "goal", "context", "config", "skills", "clear",
    "usage-credits",
  ]
  private static let codexFallbackSlash = [
    "review", "approvals", "diff", "new", "init", "skills", "agent", "apps", "plugins",
    "mcp", "mention", "fork", "resume", "memories", "goal", "fast", "personality", "logout",
  ]
  private static let claudeFallbackCli = ["agents", "config", "doctor", "mcp", "plugin", "update", "login", "logout"]
  private static let codexFallbackCli = [
    "exec", "review", "login", "logout", "mcp", "plugin", "doctor", "apply", "resume",
    "fork", "cloud", "sandbox", "update",
  ]

  private var appearance: VibeAgentKitChatAppearance = .fallback

  /// True while a bridge task is running for this chat: the trailing control becomes a
  /// STOP button (always visible, regardless of text) that cancels the run instead of
  /// sending. The host drives this from the live message state.
  private var isTaskActive = false
  private(set) var barHeight: CGFloat = 0
  /// Tracks the last-applied value of `isExpanded` / send-visibility so the bottom row
  /// and trailing control only cross-fade when either actually flips, not on every
  /// keystroke.
  private var lastExpandedState = false
  private var lastSendVisible = false
  /// The most recent keyboard show/hide curve, consumed once by the next expand/collapse
  /// so the pill's own morph rides the SAME timeline as the keyboard instead of a
  /// separately-timed spring — a mismatch there was the visible "jump".
  private var pendingKeyboardAnimation: (duration: TimeInterval, options: UIView.AnimationOptions)?

  // On-device speech dictation for the mic button: tap to start, tap to stop, the
  // recognized text fills the composer so you can edit before sending. The agents
  // are text/code CLIs, so dictation (speech → text) is the useful "record voice"
  // here, not an audio attachment they can't consume.
  private let speechRecognizer = SFSpeechRecognizer()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()
  private var isDictating = false
  private var dictationBaseText = ""

  // MARK: Layout constants
  private let sideSize: CGFloat = 46
  private let topVPad: CGFloat = 6
  private let bottomVPad: CGFloat = 6
  private let minPillH: CGFloat = 46
  private let maxPillH: CGFloat = 160
  private let textInsetH: CGFloat = 14
  private let textInsetV: CGFloat = 11
  private let pagePadding: CGFloat = 14
  private let sendButtonSize: CGFloat = 34
  // The plus/slash/permission row that appears underneath the text once expanded.
  private let bottomRowHeight: CGFloat = 34
  private let bottomIconSize: CGFloat = 32
  private let bottomRowGap: CGFloat = 8
  private var modeObserver: NSObjectProtocol?

  override init(frame: CGRect) {
    super.init(frame: frame)
    configure()
  }

  required init?(coder: NSCoder) { return nil }

  deinit {
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    recognitionTask?.cancel()
    if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
    NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
  }

  /// Keeps the permission icon (and the slash icon's plan-mode accent) in sync whether
  /// the mode was set via /plan, the header permission picker, or this composer's menu.
  private func refreshModePill() {
    updatePermissionMenu()
    updateSlashAccent()
  }

  /// Total height the host should give this view.
  var preferredHeight: CGFloat {
    topVPad + pillHeightForText() + bottomVPad + safeAreaInsets.bottom
  }

  /// True whenever the composer shows its full two-row layout — text on top, the
  /// plus/slash/permission row underneath — because it's focused or holds a draft.
  /// False collapses back to a single compact line with just the placeholder and
  /// the mic/send control, hiding the three icons entirely.
  private var isExpanded: Bool {
    textView.isFirstResponder
      || !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !pendingAttachmentBlobs.isEmpty
  }

  /// The plus/slash/permission row reserves this much height below the text, but
  /// only while expanded — collapsing drops the reservation instead of leaving a
  /// gap.
  private var bottomRowReserve: CGFloat { bottomRowHeight + bottomRowGap }

  private func pillHeightForText() -> CGFloat {
    guard isExpanded else { return minPillH }
    let measured = measuredTextHeight()
    let minTextH = minPillH - textInsetV * 2
    let maxTextHeight = max(minTextH, maxPillH - textInsetV * 2 - bottomRowReserve)
    let clampedTextH = max(minTextH, min(maxTextHeight, measured))
    return clampedTextH + textInsetV * 2 + bottomRowReserve
  }

  /// Height the text wants for the full-width row it gets — no side reservations,
  /// since the icon row now lives underneath the text instead of squeezed in
  /// beside it (which used to eat into every wrapped line, not just the last one).
  private func measuredTextHeight() -> CGFloat {
    let w = bounds.width > 0 ? bounds.width : (window?.bounds.width ?? UIScreen.main.bounds.width)
    let pillW = max(1, w - pagePadding * 2)
    let textW = max(1, pillW - textInsetH * 2)
    return textView.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height
  }

  // MARK: - Setup

  private func configure() {
    backgroundColor = .clear
    clipsToBounds = false

    // Keep the permission icon in sync with the work mode chosen anywhere (header
    // picker, /plan, etc.).
    modeObserver = NotificationCenter.default.addObserver(
      forName: AgentBridgeSelectionStore.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.refreshModePill()
    }
    // Capture the system's own keyboard timing so the pill's expand/collapse morph can
    // ride the exact same curve instead of a separately-timed spring (see
    // `pendingKeyboardAnimation`).
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleKeyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil)

    // One glass pill hosts everything; only its height changes (focus/text driven).
    configureGlass(pillGlass)
    addSubview(pillGlass)
    pillContainer.backgroundColor = .clear
    pillContainer.clipsToBounds = true
    pillContainer.layer.cornerCurve = .continuous
    pillGlass.contentView.addSubview(pillContainer)

    // The bottom row — plus / slash / permission — is its own independent tap
    // target per icon. Each opens its own menu/picker and is hidden entirely at
    // rest, appearing only once the composer expands.
    configureIconButton(plusButton, systemName: "plus")
    plusButton.addTarget(self, action: #selector(handlePlus), for: .touchUpInside)
    plusButton.showsMenuAsPrimaryAction = false
    plusButton.isHidden = true
    plusButton.alpha = 0
    pillContainer.addSubview(plusButton)

    configureIconButton(slashButton, systemName: "slash.circle")
    slashButton.showsMenuAsPrimaryAction = true
    slashButton.isHidden = true
    slashButton.alpha = 0
    pillContainer.addSubview(slashButton)
    updateSlashAccent()

    configurePermissionButton()
    permissionButton.isHidden = true
    permissionButton.alpha = 0
    pillContainer.addSubview(permissionButton)

    placeholderLabel.text = placeholder
    placeholderLabel.font = UIFont.systemFont(ofSize: 17)
    placeholderLabel.numberOfLines = 1
    placeholderLabel.isUserInteractionEnabled = false
    pillContainer.addSubview(placeholderLabel)

    textView.backgroundColor = .clear
    textView.font = UIFont.systemFont(ofSize: 17)
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.isScrollEnabled = false
    textView.returnKeyType = .default
    textView.delegate = self
    textView.showsVerticalScrollIndicator = false
    pillContainer.addSubview(textView)

    sendButton.addTarget(self, action: #selector(handleSend), for: .touchUpInside)
    sendButton.clipsToBounds = true
    sendButton.alpha = 0
    sendButton.isHidden = true
    pillContainer.addSubview(sendButton)

    configureIconButton(micButton, systemName: "mic")
    micButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 15, weight: .medium), forImageIn: .normal)
    micButton.addTarget(self, action: #selector(handleMic), for: .touchUpInside)
    pillContainer.addSubview(micButton)

    applyAppearance(.fallback)
    updateCommandMenu()
    refreshModePill()
  }

  private func configureGlass(_ view: UIVisualEffectView) {
    view.clipsToBounds = true
    view.isUserInteractionEnabled = true
    let effect = UIGlassEffect()
    effect.isInteractive = true
    view.effect = effect
    view.contentView.backgroundColor = .clear
  }

  private func configureIconButton(_ button: UIButton, systemName: String) {
    button.setImage(
      UIImage(
        systemName: systemName,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .light)),
      for: .normal)
    button.imageView?.contentMode = .scaleAspectFit
    button.backgroundColor = .clear
    button.tintColor = appearance.text.withAlphaComponent(0.6)
  }

  /// Permission is a single icon (no label) that swaps per the active work mode and
  /// opens its own menu — it never grows or resizes the composer. Its color (not just
  /// its glyph) carries the mode so it reads at a glance without needing a text label.
  private func configurePermissionButton() {
    configureIconButton(permissionButton, systemName: AgentBridgeSelectionStore.selectedWorkMode().icon)
    permissionButton.showsMenuAsPrimaryAction = true
    updatePermissionMenu()
  }

  /// One color per work mode — roughly risk-ordered (green = read-only, red = full
  /// access) so plan/ask/auto/full are visually distinguishable at a glance.
  private static func color(for mode: AgentBridgeWorkMode) -> UIColor {
    switch mode {
    case .plan: return .systemBlue
    case .readOnly: return .systemGreen
    case .ask: return .systemOrange
    case .askAuto: return .systemTeal
    case .allowEdits: return .systemPurple
    case .fullAccess: return .systemRed
    }
  }

  private func updatePermissionMenu() {
    let currentMode = AgentBridgeSelectionStore.selectedWorkMode()
    configureIconButton(permissionButton, systemName: currentMode.icon)
    permissionButton.tintColor = Self.color(for: currentMode)
    permissionButton.accessibilityLabel = "Permission: \(currentMode.title)"
    let permissionChildren = AgentBridgeWorkMode.allCases.map { mode in
      UIAction(
        title: mode.title,
        subtitle: mode.subtitle,
        image: UIImage(systemName: mode.icon)?.withTintColor(Self.color(for: mode), renderingMode: .alwaysOriginal),
        state: mode == currentMode ? .on : .off
      ) { _ in
        AgentBridgeSelectionStore.setWorkMode(mode)
      }
    }
    permissionButton.menu = UIMenu(
      title: "Permission",
      subtitle: currentMode.title,
      image: UIImage(systemName: "hand.raised"),
      children: permissionChildren)
  }

  /// The slash icon picks up the plan-mode blue too — a persistent cue that plan mode
  /// is engaged, independent of the momentary "Plan mode" toast shown when `/plan` runs.
  private func updateSlashAccent() {
    slashButton.tintColor =
      AgentBridgeSelectionStore.selectedWorkMode() == .plan
      ? .systemBlue
      : appearance.text.withAlphaComponent(0.6)
  }

  func applyAppearance(_ appearance: VibeAgentKitChatAppearance) {
    self.appearance = appearance
    backgroundColor = .clear
    textView.textColor = appearance.text
    textView.tintColor = appearance.text
    placeholderLabel.textColor = appearance.textTertiary
    plusButton.tintColor = appearance.text.withAlphaComponent(0.6)
    updateSlashAccent()
    updatePermissionMenu()
    micButton.tintColor = isDictating ? .systemRed : appearance.text.withAlphaComponent(0.6)
    applySendButtonGlyph()
    updateAttachmentIndicator()
    updateSendState()
    setNeedsLayout()
  }

  // MARK: - Layout

  public override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width
    guard w > 0 else { return }

    let expanded = isExpanded
    // While a task is running, STOP must stay reachable even if the composer is
    // collapsed/unfocused — so its collapsed layout reserves room for it too.
    let stopReserve: CGFloat = (!expanded && isTaskActive) ? sendButtonSize + 10 : 0

    let leftEdge = pagePadding
    let rightEdge = w - pagePadding
    let pillW = max(1, rightEdge - leftEdge)

    // Text always gets the full width — the icon row lives underneath it instead
    // of squeezed in beside it, so nothing eats into the text on any wrapped line.
    let textW = max(1, pillW - textInsetH * 2)
    let measured = textView.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height
    let minTextH = minPillH - textInsetV * 2
    let maxTextHeight = max(minTextH, maxPillH - textInsetV * 2 - bottomRowReserve)
    let clampedTextH = expanded ? max(minTextH, min(maxTextHeight, measured)) : minTextH
    textView.isScrollEnabled = expanded && measured > maxTextHeight
    let pillH = expanded ? clampedTextH + textInsetV * 2 + bottomRowReserve : minPillH

    let cornerR = min(pillH / 2, 22)
    pillGlass.frame = CGRect(x: leftEdge, y: topVPad, width: pillW, height: pillH)
    pillContainer.frame = pillGlass.bounds
    pillContainer.layer.cornerRadius = cornerR

    let squareBounds = CGRect(origin: .zero, size: CGSize(width: sideSize, height: sideSize))
    let bottomIconBounds = CGRect(origin: .zero, size: CGSize(width: bottomIconSize, height: bottomIconSize))
    let sendSize = CGSize(width: sendButtonSize, height: sendButtonSize)

    if expanded {
      // Row 1: the text spans the full width, top-aligned.
      textView.frame = CGRect(x: textInsetH, y: textInsetV, width: textW, height: clampedTextH)
      placeholderLabel.frame = CGRect(x: textInsetH + 2, y: textInsetV, width: textW - 4, height: clampedTextH)

      // Row 2: plus / slash / permission on the left (each padded from the edge and
      // from one another), mic + send together on the right — each its own tap
      // target with its own menu; none of them resize the pill.
      let rowCenterY = pillH - bottomRowHeight / 2
      var x = textInsetH
      for button in [plusButton, slashButton, permissionButton] {
        button.bounds = bottomIconBounds
        button.center = CGPoint(x: x + bottomIconSize / 2, y: rowCenterY)
        x += bottomIconSize + bottomRowGap
      }

      // Send sits statically next to mic once expanded — no separate "entrance" morph
      // when text starts/stops being empty, only an enabled/disabled dim (`updateSendState`).
      let sendReserve = sendButtonSize + 6
      micButton.bounds = bottomIconBounds
      micButton.center = CGPoint(x: pillW - textInsetH - bottomIconSize / 2 - sendReserve, y: rowCenterY)

      sendButton.bounds = CGRect(origin: .zero, size: sendSize)
      sendButton.center = CGPoint(x: pillW - textInsetH - sendButtonSize / 2, y: rowCenterY)
    } else {
      // Collapsed: one line — placeholder on the left, mic (+ STOP, if a task is
      // running) on the right.
      let centerY = pillH / 2
      let textRight = pillW - sideSize - stopReserve
      textView.frame = CGRect(x: textInsetH, y: centerY - minTextH / 2, width: max(1, textRight - textInsetH), height: minTextH)
      placeholderLabel.frame = textView.frame

      micButton.bounds = squareBounds
      micButton.center = CGPoint(x: pillW - sideSize / 2 - stopReserve, y: centerY)

      sendButton.bounds = CGRect(origin: .zero, size: sendSize)
      sendButton.center = CGPoint(x: pillW - 8 - sendButtonSize / 2, y: centerY)
    }
    sendButton.layer.cornerRadius = sendButtonSize / 2

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pillGlass.cornerConfiguration = .uniformCorners(radius: .fixed(cornerR))
    CATransaction.commit()

    barHeight = topVPad + pillH + bottomVPad + safeAreaInsets.bottom

    pillContainer.bringSubviewToFront(sendButton)
    pillContainer.bringSubviewToFront(plusButton)
    pillContainer.bringSubviewToFront(slashButton)
    pillContainer.bringSubviewToFront(permissionButton)
  }

  public override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    onHeightChanged?(preferredHeight)
    setNeedsLayout()
  }

  // MARK: - Send

  /// Refill the composer with an existing message's text for editing — focus it so
  /// the user can revise and resend (used by the hold menu's "Edit").
  func beginEditing(with text: String) {
    textView.text = text
    placeholderLabel.isHidden = !text.isEmpty
    updateSendState(animated: false)
    updateExpansionState(animated: false)
    textView.becomeFirstResponder()
  }

  @objc private func handleSend() {
    // While a task is running the trailing control is a STOP button — cancel the live
    // run and never send. The button reverts to send/mic when the host clears active.
    if isTaskActive {
      onStop?()
      return
    }
    stopDictation()
    let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasAttachments = !pendingAttachmentBlobs.isEmpty
    guard (!text.isEmpty || hasAttachments), onSend != nil else { return }
    if !hasAttachments, let localCommand = localCommandForComposerText(text) {
      textView.text = ""
      placeholderLabel.isHidden = false
      updateSendState(animated: true)
      updateExpansionState(animated: true)
      if localCommand == "/plan" {
        AgentBridgeSelectionStore.setWorkMode(.plan)
      }
      onCommand?(localCommand)
      return
    }
    let body = text.isEmpty && hasAttachments
      ? "Please take a look at the attached image."
      : text
    let options = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
    textView.text = ""
    placeholderLabel.isHidden = false
    updateSendState(animated: true)
    updateExpansionState(animated: true)
    onSend?(body, options)
  }

  /// Host-driven: flip the trailing control between SEND (idle) and STOP (a bridge task
  /// is running). When active the button is forced visible even while collapsed, swaps
  /// to a stop glyph, and `handleSend` routes to `onStop`.
  func setTaskActive(_ active: Bool) {
    guard isTaskActive != active else { return }
    isTaskActive = active
    applySendButtonGlyph()
    updateSendState(animated: true)
    updateExpansionState(animated: true)
  }

  /// The trailing button shows a stop square while a task runs, otherwise a plain send
  /// arrow. Both ride the same filled circle (background dims via `updateSendState`).
  private func applySendButtonGlyph() {
    let systemName = isTaskActive ? "stop.fill" : "arrow.up"
    let weight: UIImage.SymbolWeight = isTaskActive ? .regular : .bold
    sendButton.setImage(
      UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: weight))?
        .withRenderingMode(.alwaysTemplate),
      for: .normal)
    sendButton.tintColor = appearance.background
  }

  /// Send no longer has its own "entrance" animation — it sits statically next to mic
  /// whenever the composer is expanded (or a task is active), per `updateExpansionState`.
  /// This only owns the enabled/disabled dim so typing doesn't need a slide-in morph.
  private func updateSendState(animated: Bool = false) {
    let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasAttachments = !pendingAttachmentBlobs.isEmpty
    let canSend = isTaskActive || ((hasText || hasAttachments) && onSend != nil)
    sendButton.isEnabled = canSend
    let dimmedColor = appearance.text.withAlphaComponent(canSend ? 1.0 : 0.35)
    let apply = { self.sendButton.backgroundColor = dimmedColor }
    if animated {
      UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
    } else {
      apply()
    }
  }

  // MARK: - Image attachments

  @objc private func handlePlus() {
    onAttach?()
  }

  /// Build the leading "/" button's native menu (grouped Info / Options / Commands / CLI),
  /// mirroring the "+"/model/repo pickers. Selecting an item inserts args or runs it.
  private func updateSlashMenu() {
    func actions(_ cmds: [VibeAgentSlashCommand]) -> [UIMenuElement] {
      cmds.map { cmd in
        UIAction(title: cmd.display, subtitle: cmd.subtitle, image: UIImage(systemName: paletteIcon(cmd))) {
          [weak self] _ in
          self?.applyCommandSelection(cmd)
        }
      }
    }
    let all = allCommands
    var sections: [UIMenuElement] = []
    let info = all.filter { $0.kind == .bridge }
    let options = all.filter { $0.kind == .runOption }
    let slash = all.filter { $0.kind == .providerSlash }
    let cli = all.filter { $0.kind == .cli }
    if !info.isEmpty { sections.append(UIMenu(title: "Info", options: .displayInline, children: actions(info))) }
    if !options.isEmpty { sections.append(UIMenu(title: "Options", options: .displayInline, children: actions(options))) }
    if !slash.isEmpty { sections.append(UIMenu(title: "Commands", children: actions(slash))) }
    if !cli.isEmpty { sections.append(UIMenu(title: "Terminal", children: actions(cli))) }
    slashButton.menu = UIMenu(title: "Slash commands", children: sections)
  }

  /// Only RUN-OPTION commands are handled locally (they configure the next run). Info
  /// commands (`/usage`, `/status`, `/commands`, `/compact`, `/doctor`, …) now fall
  /// through to `onSend` so the BRIDGE runs them and returns real CLI/account output —
  /// they used to render local mock panels, which is what felt fake.
  private func localCommandForComposerText(_ text: String) -> String? {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.hasPrefix("/") else { return nil }
    let name = normalized.dropFirst().split(separator: " ").first.map(String.init) ?? ""
    switch name {
    case "plan": return "/plan"
    case "reasoning", "thinking": return "/reasoning"
    default: return nil
    }
  }

  // The "+" button is purely attachments. Slash commands are opened by the outside
  // plain "/" button.
  private func updateCommandMenu() {
    plusButton.menu = nil
    plusButton.showsMenuAsPrimaryAction = false
    updateSlashMenu()
  }

  /// Stage an encrypted image blob to ride along with the next send. The "+" button
  /// reflects how many are queued so the user knows an image is attached.
  func addAttachment(blob: String) {
    pendingAttachmentBlobs.append(blob)
    updateAttachmentIndicator()
    updateSendState(animated: true)
    updateExpansionState(animated: true)
  }

  /// Hand the staged blobs to the caller and clear them (called at send time).
  func consumePendingAttachments() -> [String] {
    let blobs = pendingAttachmentBlobs
    pendingAttachmentBlobs.removeAll()
    updateAttachmentIndicator()
    updateSendState(animated: true)
    updateExpansionState(animated: true)
    return blobs
  }

  private func updateAttachmentIndicator() {
    let count = pendingAttachmentBlobs.count
    plusButton.setImage(
      UIImage(
        systemName: count > 0 ? "photo.badge.plus.fill" : "plus",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)),
      for: .normal)
    plusButton.tintColor = count > 0 ? .systemBlue : appearance.text.withAlphaComponent(0.6)
    plusButton.accessibilityValue = count > 0 ? "\(count) image(s) attached" : nil
  }

  // MARK: - Voice dictation

  @objc private func handleMic() {
    if isDictating {
      stopDictation()
      return
    }
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard let self, status == .authorized else { return }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async {
            guard granted else { return }
            self.startDictation()
          }
        }
      }
    }
  }

  private func startDictation() {
    guard let recognizer = speechRecognizer, recognizer.isAvailable, !isDictating else { return }
    recognitionTask?.cancel()
    recognitionTask = nil

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      return
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    recognitionRequest = request
    // Preserve anything already typed; append dictated text after it.
    let existing = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    dictationBaseText = existing.isEmpty ? "" : existing + " "

    let inputNode = audioEngine.inputNode
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      // The recognition handler is called on an arbitrary queue; touch UI/audio on main.
      DispatchQueue.main.async {
        guard let self else { return }
        if let result {
          self.textView.text = self.dictationBaseText + result.bestTranscription.formattedString
          self.textViewDidChange(self.textView)
        }
        if error != nil || (result?.isFinal ?? false) {
          self.stopDictation()
        }
      }
    }

    let format = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
      isDictating = true
      updateMicAppearance()
    } catch {
      stopDictation()
    }
  }

  private func stopDictation() {
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    recognitionTask?.cancel()
    recognitionTask = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    if isDictating {
      isDictating = false
      updateMicAppearance()
    }
  }

  private func updateMicAppearance() {
    micButton.setImage(
      UIImage(
        systemName: isDictating ? "mic.fill" : "mic",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)),
      for: .normal)
    micButton.tintColor = isDictating ? .systemRed : appearance.text.withAlphaComponent(0.6)
  }

  // MARK: - UITextViewDelegate

  public func textViewDidChange(_ textView: UITextView) {
    placeholderLabel.isHidden = !textView.text.isEmpty
    updateSendState(animated: true)
    updateExpansionState(animated: true)
  }

  public func textViewDidBeginEditing(_ textView: UITextView) {
    updateExpansionState(animated: true)
  }

  public func textViewDidEndEditing(_ textView: UITextView) {
    updateExpansionState(animated: true)
  }

  /// Captures the system's keyboard timing so the very next expand/collapse can reuse
  /// it instead of a hand-picked spring (see `pendingKeyboardAnimation`).
  @objc private func handleKeyboardWillChangeFrame(_ note: Notification) {
    guard let info = note.userInfo,
      let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue,
      duration > 0,
      let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue
    else { return }
    pendingKeyboardAnimation = (duration, UIView.AnimationOptions(rawValue: curveRaw << 16))
  }

  /// Cross-fades the plus/slash/permission row (visible while `isExpanded`) and the
  /// trailing send/stop control (visible while expanded OR a task is running), and
  /// resizes the pill to match — all in ONE animation. `onHeightChanged` fires from
  /// INSIDE that animation's closure (not before it starts) so the host's height
  /// constraint and this view's own icon/frame changes share a single Core Animation
  /// transaction; layering a second, differently-timed animation on top of the first
  /// is what caused the visible "jump" between the pill and the keyboard. When the
  /// change is keyboard-driven, `pendingKeyboardAnimation` supplies the exact system
  /// curve so the morph rides the same timeline as the keyboard itself.
  private func updateExpansionState(animated: Bool) {
    let expanded = isExpanded
    let sendVisible = isTaskActive || expanded
    guard expanded != lastExpandedState || sendVisible != lastSendVisible else { return }
    lastExpandedState = expanded
    lastSendVisible = sendVisible
    if expanded {
      plusButton.isHidden = false
      slashButton.isHidden = false
      permissionButton.isHidden = false
    }
    if sendVisible {
      sendButton.isHidden = false
    }
    let newHeight = preferredHeight
    let apply = {
      self.onHeightChanged?(newHeight)
      self.plusButton.alpha = expanded ? 1 : 0
      self.slashButton.alpha = expanded ? 1 : 0
      self.permissionButton.alpha = expanded ? 1 : 0
      self.sendButton.alpha = sendVisible ? 1 : 0
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
    let finish: (Bool) -> Void = { _ in
      if !expanded {
        self.plusButton.isHidden = true
        self.slashButton.isHidden = true
        self.permissionButton.isHidden = true
      }
      if !sendVisible {
        self.sendButton.isHidden = true
      }
    }
    guard animated else {
      apply()
      finish(true)
      return
    }
    if let kb = pendingKeyboardAnimation {
      pendingKeyboardAnimation = nil
      UIView.animate(
        withDuration: kb.duration, delay: 0,
        options: kb.options.union([.beginFromCurrentState, .allowUserInteraction]),
        animations: apply, completion: finish)
    } else {
      UIView.animate(
        withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
        options: [.beginFromCurrentState, .allowUserInteraction], animations: apply, completion: finish)
    }
  }

  // MARK: - `/` commands

  private var allCommands: [VibeAgentSlashCommand] {
    Self.defaultCommands + providerSlashCommands + providerCliCommands
  }

  /// Inject the provider's reported slash + CLI commands (from the latest runtime
  /// metadata) so the palette lists everything the connected CLI exposes, not just the
  /// built-in bridge commands. Deduped against the defaults.
  func setProviderCommands(slash: [String], cli: [String]) {
    func clean(_ raw: String) -> String {
      raw.trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .lowercased()
    }
    let isCodex = provider.lowercased().contains("codex")
    func subtitle(_ n: String, isCli: Bool) -> String {
      var s = Self.commandDescriptions[n] ?? (isCli ? "Terminal subcommand" : "Slash command")
      if isCodex && Self.codexDesktopOnly.contains(n) { s += " · desktop only" }
      return s
    }
    // Fall back to the provider's full catalog until a run delivers the real one, so the
    // palette is complete from the first `/` in a brand-new chat.
    let slashSource = slash.isEmpty ? (isCodex ? Self.codexFallbackSlash : Self.claudeFallbackSlash) : slash
    let cliSource = cli.isEmpty ? (isCodex ? Self.codexFallbackCli : Self.claudeFallbackCli) : cli
    var seen = Set(Self.defaultCommands.map { $0.name.lowercased() })
    providerSlashCommands = slashSource.compactMap { item in
      let n = clean(item)
      guard !n.isEmpty, !seen.contains(n) else { return nil }
      seen.insert(n)
      return VibeAgentSlashCommand(name: n, subtitle: subtitle(n, isCli: false), kind: .providerSlash, takesArgs: true)
    }
    providerCliCommands = cliSource.compactMap { item in
      let n = clean(item)
      guard !n.isEmpty, !seen.contains(n) else { return nil }
      seen.insert(n)
      return VibeAgentSlashCommand(name: n, subtitle: subtitle(n, isCli: true), kind: .cli, takesArgs: true)
    }
    updateSlashMenu()
  }

  private func applyCommandSelection(_ cmd: VibeAgentSlashCommand) {
    if cmd.takesArgs {
      // Let the user add arguments — insert and keep editing.
      textView.text = cmd.display + " "
      placeholderLabel.isHidden = true
      updateSendState(animated: true)
      updateExpansionState(animated: true)
      textView.becomeFirstResponder()
    } else {
      // No args → run immediately. handleSend() routes run-options locally and every
      // other command to the bridge for real output.
      textView.text = cmd.display
      handleSend()
    }
  }

  private func paletteIcon(_ cmd: VibeAgentSlashCommand) -> String {
    switch cmd.name {
    case "usage": return "gauge.with.dots.needle.bottom.50percent"
    case "status": return "info.circle"
    case "commands": return "terminal"
    case "doctor": return "stethoscope"
    case "compact": return "rectangle.compress.vertical"
    case "model": return "cpu"
    case "plan": return "checklist"
    case "reasoning": return "brain"
    case "review", "security-review": return "magnifyingglass"
    case "init": return "doc.badge.plus"
    case "context": return "doc.text.magnifyingglass"
    case "mcp": return "server.rack"
    default: return cmd.kind == .cli ? "terminal" : "slash.circle"
    }
  }
}

// MARK: - Read-only subagent detail (Claude Task tool)

/// A read-only view of one subagent's steps — no composer, no send, just the live
/// Read/Edit/Run feed. Opened from the "Subagent" feed row or its start toast;
/// the host VC calls `update(children:running:)` each transcript tick so it streams.
final class VibeAgentSubagentDetailViewController: UIViewController {
  var onClose: (() -> Void)?

  private let appearance: VibeAgentKitChatAppearance
  private let subagentType: String
  private var progressItems: [VibeAgentKitProgressItem]
  private var running: Bool

  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let emptyLabel = UILabel()
  private let scrollView = UIScrollView()
  private let rowsStack = UIStackView()

  init(
    subagentType: String,
    progressItems: [VibeAgentKitProgressItem],
    running: Bool,
    appearance: VibeAgentKitChatAppearance
  ) {
    self.subagentType = subagentType
    self.progressItems = progressItems
    self.running = running
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = appearance.background

    let header = UIView()
    header.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(header)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
    titleLabel.textColor = appearance.text
    let flavor = subagentType.trimmingCharacters(in: .whitespacesAndNewlines)
    titleLabel.text = flavor.isEmpty ? "Subagent" : "Subagent · \(flavor)"
    header.addSubview(titleLabel)

    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    subtitleLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .regular)
    subtitleLabel.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.85)
    header.addSubview(subtitleLabel)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    spinner.color = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.85)
    header.addSubview(spinner)

    let closeButton = UIButton(type: .system)
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    closeButton.tintColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.6)
    closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
    header.addSubview(closeButton)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    view.addSubview(scrollView)

    rowsStack.translatesAutoresizingMaskIntoConstraints = false
    rowsStack.axis = .vertical
    rowsStack.alignment = .fill
    rowsStack.spacing = 12.0
    rowsStack.isLayoutMarginsRelativeArrangement = true
    rowsStack.layoutMargins = UIEdgeInsets(top: 14.0, left: 18.0, bottom: 24.0, right: 18.0)
    scrollView.addSubview(rowsStack)

    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    emptyLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
    emptyLabel.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.7)
    emptyLabel.numberOfLines = 0
    emptyLabel.textAlignment = .center
    emptyLabel.text = "Waiting for the subagent's first step…"
    view.addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      header.heightAnchor.constraint(equalToConstant: 56.0),

      titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18.0),
      titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 8.0),

      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1.0),

      spinner.leadingAnchor.constraint(equalTo: subtitleLabel.trailingAnchor, constant: 8.0),
      spinner.centerYAnchor.constraint(equalTo: subtitleLabel.centerYAnchor),

      closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16.0),
      closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 26.0),
      closeButton.heightAnchor.constraint(equalToConstant: 26.0),

      scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      rowsStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      rowsStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
      rowsStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
      rowsStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

      emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32.0),
      emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32.0),
    ])

    rebuild()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || isMovingFromParent { onClose?() }
  }

  func update(progressItems: [VibeAgentKitProgressItem], running: Bool) {
    self.progressItems = progressItems
    self.running = running
    if isViewLoaded { rebuild() }
  }

  private func rebuild() {
    rowsStack.arrangedSubviews.forEach {
      rowsStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    let toolChildren = progressItems.filter { $0.itemType != "text" }
    emptyLabel.isHidden = !progressItems.isEmpty
    for child in progressItems {
      rowsStack.addArrangedSubview(makeRow(for: child))
    }
    subtitleLabel.text = running
      ? "Running · \(toolChildren.count) \(toolChildren.count == 1 ? "step" : "steps")"
      : "\(toolChildren.count) \(toolChildren.count == 1 ? "step" : "steps")"
    if running { spinner.startAnimating() } else { spinner.stopAnimating() }
  }

  private func makeRow(for item: VibeAgentKitProgressItem) -> UIView {
    let kind = (item.itemType ?? item.tool ?? "").lowercased()

    // Narration text node: render as plain prose (no icon), matching the main feed.
    if kind == "text" {
      let label = UILabel()
      label.translatesAutoresizingMaskIntoConstraints = false
      label.numberOfLines = 0
      label.font = UIFont.systemFont(ofSize: 15.0, weight: .regular)
      label.textColor = appearance.text
      label.text = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
      return label
    }

    let row = UIStackView()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.axis = .horizontal
    row.alignment = .top
    row.spacing = 9.0

    let icon = UIImageView()
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.contentMode = .scaleAspectFit
    icon.image = UIImage(systemName: Self.iconName(for: kind))?.withRenderingMode(.alwaysTemplate)
    icon.tintColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.75)
    icon.setContentHuggingPriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 15.0),
      icon.heightAnchor.constraint(equalToConstant: 15.0),
    ])

    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    if kind == "bash", let cmd = item.command, !cmd.isEmpty {
      label.numberOfLines = 1
      label.attributedText = NSAttributedString(
        string: cmd.replacingOccurrences(of: "\n", with: " "),
        attributes: [
          .font: UIFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
          .foregroundColor: appearance.text,
        ])
    } else {
      var text = item.label
      if kind == "read", let start = item.lineStart {
        let range = item.lineEnd.map { "\(start)–\($0)" } ?? "\(start)"
        text += "  (\(range))"
      }
      label.font = UIFont.systemFont(ofSize: 14.75, weight: .regular)
      label.textColor = appearance.text
      label.text = text
    }

    // `.top` alignment already pins the icon to the first text line; an extra
    // icon.top→row.top constraint both crashes (activated pre-hierarchy) and
    // conflicts with the stack's own required top-alignment constraint.
    row.addArrangedSubview(icon)
    row.addArrangedSubview(label)
    return row
  }

  private static func iconName(for kind: String) -> String {
    switch kind {
    case "read": return "doc.text"
    case "edit", "write": return "pencil"
    case "bash": return "terminal"
    case "search": return "magnifyingglass"
    case "web": return "globe"
    case "thinking": return "brain"
    case "task": return "person.2"
    default: return "circle.dotted"
    }
  }
}

// MARK: - Ask / plan-approval sheet

/// The phone's approver surface for a bridge `ask_request`. Two kinds:
///   • `plan` — shows the proposed plan + Reject / Approve & Implement (with an
///     optional notes field). Approving re-runs the turn with edits enabled.
///   • `ask`  — renders the agent's `questions[]` (the AskUserQuestion shape:
///     header chip, single/multi-select options, an "Other" field) → Submit.
/// Resolves exactly once via `onResolve(decision, answer)` then dismisses.
final class VibeAgentAskSheetViewController: UIViewController {
  /// (decision, answer). decision ∈ "approve" | "reject" | "answer".
  var onResolve: ((String, [String: Any]?) -> Void)?
  /// Fired when the sheet is dismissed WITHOUT a decision (user swiped it away). Lets
  /// the presenter release its presentation claim so a still-pending ask re-shows when
  /// the chat is reopened (the bridge re-emits it on history open).
  var onDismissWithoutResolve: (() -> Void)?

  private let kind: String
  private let request: [String: Any]
  private let appearance: VibeAgentKitChatAppearance
  private var didResolve = false

  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private let feedbackView = UITextView()
  private let feedbackPlaceholder = UILabel()

  // ask-mode question state, parallel to `questions`.
  private struct AskQuestion {
    let question: String
    let header: String
    let multiSelect: Bool
    let options: [String]
  }
  private var questions: [AskQuestion] = []
  private var selected: [Set<Int>] = []
  private var otherFields: [UITextField] = []
  private var optionButtonsByQuestion: [[UIButton]] = []

  // Multi-question asks are paginated one-per-page (Question 1 of N). Blocks are
  // built once so selections/Other text persist as the user pages back and forth.
  private var questionBlocks: [UIView] = []
  private var askPageIndex = 0
  private let pageIndicator = UILabel()
  private weak var askBackButton: UIButton?
  private weak var askNextButton: UIButton?

  init(kind: String, request: [String: Any], appearance: VibeAgentKitChatAppearance) {
    self.kind = kind
    self.request = request
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  // Off-mute neutral palette (no brand brown/orange) for the glass sheet.
  private var neutralAccent: UIColor {
    appearance.isDark ? UIColor(white: 0.95, alpha: 1.0) : UIColor(white: 0.13, alpha: 1.0)
  }
  private var neutralAccentText: UIColor {
    appearance.isDark ? .black : .white
  }
  private var neutralFill: UIColor {
    appearance.isDark
      ? UIColor.white.withAlphaComponent(0.10) : UIColor.black.withAlphaComponent(0.05)
  }
  private var neutralStroke: UIColor {
    appearance.isDark
      ? UIColor.white.withAlphaComponent(0.18) : UIColor.black.withAlphaComponent(0.12)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Glass sheet (mirrors the chat attachment/share sheet) instead of the solid
    // warm/brown agent background. Neutral, off-mute palette is used throughout.
    view.backgroundColor = .clear
    let glassView = UIVisualEffectView(effect: nil)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = true
      glassView.effect = glass
    } else {
      glassView.effect = UIBlurEffect(
        style: appearance.isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight)
    }
    glassView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(glassView)
    NSLayoutConstraint.activate([
      glassView.topAnchor.constraint(equalTo: view.topAnchor),
      glassView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      glassView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.keyboardDismissMode = .interactive
    view.addSubview(scrollView)

    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .vertical
    contentStack.spacing = 14
    contentStack.alignment = .fill
    scrollView.addSubview(contentStack)

    // Parse questions before the bar so it can choose paged (Back/Next) vs single Submit.
    if kind != "plan" && kind != "command" { parseQuestions() }
    let buttonBar = makeButtonBar()
    buttonBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(buttonBar)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor),

      contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
      contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
      contentStack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -40),

      buttonBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      buttonBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      buttonBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
    ])

    if kind == "plan" {
      buildPlanContent()
    } else if kind == "command" {
      buildCommandContent()
    } else {
      buildAskContent()
    }
  }

  // MARK: content

  private func titleLabel(_ text: String, size: CGFloat = 20, weight: UIFont.Weight = .bold) -> UILabel {
    let label = UILabel()
    label.text = text
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = appearance.text
    return label
  }

  private func bodyLabel(_ text: String, color: UIColor? = nil) -> UILabel {
    let label = UILabel()
    label.text = text
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: 14.5)
    label.textColor = color ?? appearance.textSecondary
    return label
  }

  private func buildPlanContent() {
    contentStack.addArrangedSubview(titleLabel("Review the plan"))
    if let repo = (request["repoName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !repo.isEmpty
    {
      contentStack.addArrangedSubview(bodyLabel("\(repo) · the agent will not edit until you approve", color: appearance.textTertiary))
    }

    let planText = (request["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no plan text)"
    let card = UIView()
    card.backgroundColor = neutralFill
    card.layer.cornerRadius = 14
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 1
    card.layer.borderColor = neutralStroke.cgColor
    let planLabel = UILabel()
    planLabel.text = planText
    planLabel.numberOfLines = 0
    planLabel.font = .systemFont(ofSize: 14)
    planLabel.textColor = appearance.text
    planLabel.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(planLabel)
    NSLayoutConstraint.activate([
      planLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
      planLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      planLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
      planLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
    ])
    contentStack.addArrangedSubview(card)

    contentStack.addArrangedSubview(bodyLabel("Notes for the agent (optional)", color: appearance.textTertiary))
    contentStack.addArrangedSubview(makeFeedbackField())
  }

  /// Command-approval card: a placeholder describing what the agent wants to do +
  /// the literal command/file it targets. Resolved via Approve / Skip / Deny.
  private func buildCommandContent() {
    let toolName = (request["toolName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let title = (request["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    contentStack.addArrangedSubview(titleLabel(title?.isEmpty == false ? title! : "Approve this action"))

    let repo = (request["repoName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let subtitle =
      toolName.isEmpty
      ? "The agent is requesting permission to continue."
      : "The agent wants to use \(toolName)."
    contentStack.addArrangedSubview(
      bodyLabel(repo?.isEmpty == false ? "\(repo!) · \(subtitle)" : subtitle, color: appearance.textTertiary))

    let command = (request["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !command.isEmpty {
      let card = UIView()
      card.backgroundColor = neutralFill
      card.layer.cornerRadius = 14
      card.layer.cornerCurve = .continuous
      card.layer.borderWidth = 1
      card.layer.borderColor = neutralStroke.cgColor
      let mono = UILabel()
      mono.text = command
      mono.numberOfLines = 0
      mono.font = .monospacedSystemFont(ofSize: 13.5, weight: .regular)
      mono.textColor = appearance.text
      mono.translatesAutoresizingMaskIntoConstraints = false
      card.addSubview(mono)
      NSLayoutConstraint.activate([
        mono.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
        mono.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
        mono.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        mono.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
      ])
      contentStack.addArrangedSubview(card)
    }

    let description = (request["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !description.isEmpty {
      contentStack.addArrangedSubview(bodyLabel(description))
    }
    contentStack.addArrangedSubview(
      bodyLabel(
        "Approve runs it once · Skip continues without it · Deny stops the agent.",
        color: appearance.textTertiary))
    contentStack.addArrangedSubview(makeFeedbackField())
  }

  /// Decode the questions[] payload and pre-build one block per question. Called
  /// before the button bar so it can size the bar to the page count.
  private func parseQuestions() {
    let rawQuestions = (request["questions"] as? [[String: Any]]) ?? []
    for q in rawQuestions {
      let questionText = (q["question"] as? String) ?? ""
      let header = (q["header"] as? String) ?? ""
      let multi = (q["multiSelect"] as? Bool) ?? false
      let opts = ((q["options"] as? [[String: Any]]) ?? []).compactMap { $0["label"] as? String }
      let model = AskQuestion(question: questionText, header: header, multiSelect: multi, options: opts)
      let index = questions.count
      questions.append(model)
      selected.append([])
      questionBlocks.append(makeQuestionBlock(model, index: index))
    }
  }

  private func buildAskContent() {
    if questions.isEmpty {
      contentStack.addArrangedSubview(titleLabel("A few questions"))
      contentStack.addArrangedSubview(bodyLabel("The agent asked a question but sent no options. Add a note below.", color: appearance.textTertiary))
      contentStack.addArrangedSubview(makeFeedbackField())
    } else {
      renderAskPage()
    }
  }

  /// Swap the visible question to `askPageIndex` (one question per page) and update
  /// the page counter + Back/Next/Submit button bar.
  private func renderAskPage() {
    guard !questions.isEmpty else { return }
    askPageIndex = min(max(askPageIndex, 0), questions.count - 1)
    for sub in contentStack.arrangedSubviews {
      contentStack.removeArrangedSubview(sub)
      sub.removeFromSuperview()
    }
    if questions.count > 1 {
      pageIndicator.text = "Question \(askPageIndex + 1) of \(questions.count)"
      pageIndicator.font = .systemFont(ofSize: 12, weight: .semibold)
      pageIndicator.textColor = appearance.textTertiary
      contentStack.addArrangedSubview(pageIndicator)
    }
    contentStack.addArrangedSubview(questionBlocks[askPageIndex])

    let isLast = askPageIndex >= questions.count - 1
    askBackButton?.isHidden = askPageIndex == 0
    askNextButton?.setTitle(isLast ? "Submit" : "Next", for: .normal)
    scrollView.setContentOffset(.zero, animated: false)
  }

  private func makeQuestionBlock(_ q: AskQuestion, index: Int) -> UIView {
    let block = UIStackView()
    block.axis = .vertical
    block.spacing = 8
    block.alignment = .fill

    if !q.header.isEmpty {
      let chip = UILabel()
      chip.text = "  \(q.header.uppercased())  "
      chip.font = .systemFont(ofSize: 11, weight: .bold)
      chip.textColor = appearance.text
      chip.backgroundColor = neutralFill
      chip.layer.cornerRadius = 7
      chip.layer.masksToBounds = true
      chip.setContentHuggingPriority(.required, for: .horizontal)
      let wrap = UIStackView(arrangedSubviews: [chip, UIView()])
      wrap.axis = .horizontal
      block.addArrangedSubview(wrap)
    }
    if !q.question.isEmpty {
      block.addArrangedSubview(titleLabel(q.question, size: 15.5, weight: .semibold))
    }
    if q.multiSelect {
      block.addArrangedSubview(bodyLabel("Select all that apply", color: appearance.textTertiary))
    }

    var buttons: [UIButton] = []
    for (optIndex, label) in q.options.enumerated() {
      let button = makeOptionButton(label, questionIndex: index, optionIndex: optIndex)
      buttons.append(button)
      block.addArrangedSubview(button)
    }
    optionButtonsByQuestion.append(buttons)

    let other = UITextField()
    other.placeholder = "Other…"
    other.font = .systemFont(ofSize: 14.5)
    other.textColor = appearance.text
    other.borderStyle = .roundedRect
    other.backgroundColor = neutralFill
    other.heightAnchor.constraint(equalToConstant: 40).isActive = true
    otherFields.append(other)
    block.addArrangedSubview(other)

    return block
  }

  private func makeOptionButton(_ label: String, questionIndex: Int, optionIndex: Int) -> UIButton {
    var config = UIButton.Configuration.bordered()
    config.title = label
    config.baseForegroundColor = appearance.text
    config.background.backgroundColor = neutralFill
    config.background.strokeColor = neutralStroke
    config.background.strokeWidth = 1
    config.background.cornerRadius = 12
    config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14)
    config.titleAlignment = .leading
    let button = UIButton(configuration: config)
    button.contentHorizontalAlignment = .leading
    button.tag = questionIndex * 1000 + optionIndex
    button.addTarget(self, action: #selector(optionTapped(_:)), for: .touchUpInside)
    return button
  }

  @objc private func optionTapped(_ sender: UIButton) {
    let questionIndex = sender.tag / 1000
    let optionIndex = sender.tag % 1000
    guard questionIndex < questions.count else { return }
    let multi = questions[questionIndex].multiSelect
    if multi {
      if selected[questionIndex].contains(optionIndex) {
        selected[questionIndex].remove(optionIndex)
      } else {
        selected[questionIndex].insert(optionIndex)
      }
    } else {
      selected[questionIndex] = [optionIndex]
    }
    refreshOptionStyles(questionIndex: questionIndex)
  }

  private func refreshOptionStyles(questionIndex: Int) {
    guard questionIndex < optionButtonsByQuestion.count else { return }
    for (optIndex, button) in optionButtonsByQuestion[questionIndex].enumerated() {
      let isOn = selected[questionIndex].contains(optIndex)
      var config = button.configuration
      config?.background.backgroundColor =
        isOn ? neutralAccent.withAlphaComponent(appearance.isDark ? 0.20 : 0.12) : neutralFill
      config?.background.strokeColor = isOn ? neutralAccent : neutralStroke
      config?.background.strokeWidth = isOn ? 1.5 : 1
      config?.baseForegroundColor = appearance.text
      button.configuration = config
    }
  }

  private func makeFeedbackField() -> UIView {
    let container = UIView()
    container.backgroundColor = neutralFill
    container.layer.cornerRadius = 12
    container.layer.cornerCurve = .continuous
    container.layer.borderWidth = 1
    container.layer.borderColor = neutralStroke.cgColor

    feedbackView.translatesAutoresizingMaskIntoConstraints = false
    feedbackView.backgroundColor = .clear
    feedbackView.font = .systemFont(ofSize: 14.5)
    feedbackView.textColor = appearance.text
    feedbackView.delegate = self
    feedbackView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
    container.addSubview(feedbackView)

    feedbackPlaceholder.text = "Add notes or changes…"
    feedbackPlaceholder.font = .systemFont(ofSize: 14.5)
    feedbackPlaceholder.textColor = appearance.textTertiary
    feedbackPlaceholder.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(feedbackPlaceholder)

    NSLayoutConstraint.activate([
      feedbackView.topAnchor.constraint(equalTo: container.topAnchor),
      feedbackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
      feedbackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
      feedbackView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      feedbackView.heightAnchor.constraint(equalToConstant: 72),
      feedbackPlaceholder.topAnchor.constraint(equalTo: feedbackView.topAnchor, constant: 11),
      feedbackPlaceholder.leadingAnchor.constraint(equalTo: feedbackView.leadingAnchor, constant: 12),
    ])
    return container
  }

  // MARK: buttons

  private func makeButtonBar() -> UIView {
    let bar = UIStackView()
    bar.axis = .horizontal
    bar.spacing = 12
    bar.distribution = .fillEqually
    bar.isLayoutMarginsRelativeArrangement = true
    bar.layoutMargins = UIEdgeInsets(top: 8, left: 20, bottom: 0, right: 20)

    if kind == "command" {
      // Live command approval: Deny · Skip · Approve.
      let deny = makeBarButton("Deny", primary: false)
      deny.addTarget(self, action: #selector(denyCommandTapped), for: .touchUpInside)
      let skip = makeBarButton("Skip", primary: false)
      skip.addTarget(self, action: #selector(skipCommandTapped), for: .touchUpInside)
      let approve = makeBarButton("Approve", primary: true)
      approve.addTarget(self, action: #selector(approveCommandTapped), for: .touchUpInside)
      bar.addArrangedSubview(deny)
      bar.addArrangedSubview(skip)
      bar.addArrangedSubview(approve)
    } else if kind == "plan" {
      let reject = makeBarButton("Reject", primary: false)
      reject.addTarget(self, action: #selector(rejectTapped), for: .touchUpInside)
      let approve = makeBarButton("Approve & Implement", primary: true)
      approve.addTarget(self, action: #selector(approveTapped), for: .touchUpInside)
      bar.addArrangedSubview(reject)
      bar.addArrangedSubview(approve)
    } else if questions.count > 1 {
      // Paged ask: Back (hidden on page 1) + Next/Submit.
      let back = makeBarButton("Back", primary: false)
      back.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
      back.isHidden = true
      let next = makeBarButton("Next", primary: true)
      next.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
      askBackButton = back
      askNextButton = next
      bar.addArrangedSubview(back)
      bar.addArrangedSubview(next)
    } else {
      let submit = makeBarButton("Submit", primary: true)
      submit.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
      askNextButton = submit
      bar.addArrangedSubview(submit)
    }
    return bar
  }

  @objc private func backTapped() {
    askPageIndex -= 1
    renderAskPage()
  }

  @objc private func nextTapped() {
    if askPageIndex >= questions.count - 1 {
      submitTapped()
    } else {
      askPageIndex += 1
      renderAskPage()
    }
  }

  private func makeBarButton(_ title: String, primary: Bool) -> UIButton {
    var config = UIButton.Configuration.filled()
    config.title = title
    // Full-radius (capsule) buttons with neutral off-mute fills.
    config.cornerStyle = .capsule
    config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
    config.baseBackgroundColor = primary ? neutralAccent : neutralFill
    config.baseForegroundColor = primary ? neutralAccentText : appearance.text
    let button = UIButton(configuration: config)
    button.titleLabel?.adjustsFontSizeToFitWidth = true
    button.titleLabel?.minimumScaleFactor = 0.8
    return button
  }

  private var feedbackText: String? {
    let t = feedbackView.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (t?.isEmpty == false) ? t : nil
  }

  @objc private func approveTapped() {
    resolve("approve", answer: feedbackText.map { ["feedback": $0] })
  }

  @objc private func rejectTapped() {
    resolve("reject", answer: feedbackText.map { ["feedback": $0] })
  }

  // Command approval (kind == "command"). A typed note becomes the message handed
  // back to the agent so it knows why a command was skipped/denied.
  @objc private func approveCommandTapped() {
    resolve("approve", answer: nil)
  }

  @objc private func skipCommandTapped() {
    resolve("skip", answer: feedbackText.map { ["message": $0] })
  }

  @objc private func denyCommandTapped() {
    resolve("deny", answer: feedbackText.map { ["message": $0] })
  }

  @objc private func submitTapped() {
    var selections: [[String: Any]] = []
    for (index, q) in questions.enumerated() {
      let labels = selected[index].sorted().compactMap { q.options.indices.contains($0) ? q.options[$0] : nil }
      let other = otherFields.indices.contains(index)
        ? otherFields[index].text?.trimmingCharacters(in: .whitespacesAndNewlines)
        : nil
      var entry: [String: Any] = ["header": q.header, "question": q.question, "selected": labels]
      if let other, !other.isEmpty {
        entry["other"] = other
      }
      selections.append(entry)
    }
    var answer: [String: Any] = ["selections": selections]
    if questions.isEmpty, let note = feedbackText { answer["feedback"] = note }
    resolve("answer", answer: answer)
  }

  private func resolve(_ decision: String, answer: [String: Any]?) {
    guard !didResolve else { return }
    didResolve = true
    onResolve?(decision, answer)
    dismiss(animated: true)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Swiped away without answering → let the presenter re-arm this ask for reopen.
    if !didResolve, isBeingDismissed || isMovingFromParent {
      onDismissWithoutResolve?()
    }
  }
}

extension VibeAgentAskSheetViewController: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    feedbackPlaceholder.isHidden = !(textView.text?.isEmpty ?? true)
  }
}
