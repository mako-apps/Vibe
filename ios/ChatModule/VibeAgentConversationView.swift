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
      lineEnd: node.end
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
    // A turn's tool actions render natively: each depth-0 node becomes a progress
    // item (compact shimmer line + tap-to-open tool sheet). The decrypted detail
    // (command OUTPUT, todo contents) becomes each row's expandable body.
    let detailMap: [String: [String: Any]] = row.isAgentMessage ? actionDetailMap(for: row) : [:]
    let items = row.isAgentMessage
      ? row.agentProgressNodes.filter { $0.depth == 0 }.map { progressItem(from: $0, detail: detailMap[$0.id]) }
      : []
    if row.isAgentMessage {
      NSLog(
        "[AgentView] map.chatMessage id=\(row.messageId ?? row.key) isUser=\(isUser) "
          + "runtime?=\(row.agentRuntime != nil) diffFiles=\(row.agentRuntime?.diff?.files.count ?? -1) "
          + "progressNodes(total=\(row.agentProgressNodes.count), depth0=\(items.count)) bodyLen=\(body.count)")
    }
    return VibeAgentKitChatMessage(
      id: row.messageId ?? row.key,
      role: isUser ? .user : .assistant,
      text: body,
      timestamp: row.timestamp,
      timestampMs: 0,
      isStreaming: row.isAgentMessage && row.isStreamingText && !isCompaction,
      isError: row.status == "failed",
      progress: [],
      progressItems: isCompaction ? [] : items,
      runtime: isCompaction ? nil : (row.isAgentMessage ? row.agentRuntime : nil),
      isCompactionSummary: isCompaction
    )
  }

  /// Build the seed message list for a task. `rows` should already be the slice of
  /// chat rows that belong to this task (the prompt + the agent reply, and any
  /// prior turns when resumed).
  static func messages(from rows: [ChatListRow]) -> [VibeAgentKitChatMessage] {
    rows.compactMap { row in
      guard case .message = row.kind else { return nil }
      // Skip empty system/placeholder rows — but KEEP a freshly-started streaming
      // row even before it has text/steps/runtime, so the live "Working…" loader
      // appears the instant a run begins instead of the view looking like nothing
      // is happening.
      let m = chatMessage(from: row)
      if m.text.isEmpty && m.progressItems.isEmpty && m.runtime == nil && !m.isStreaming {
        return nil
      }
      return m
    }
  }
}

// MARK: - Full-page agent conversation surface

final class VibeAgentConversationViewController: UIViewController, UITableViewDataSource,
  UITableViewDelegate, PHPickerViewControllerDelegate
{

  private let tableView = UITableView(frame: .zero, style: .plain)
  private let progressSheet = VibeAgentKitAgentProgressSheetView()
  private let composerView = VibeAgentRuntimeComposerView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let liveDotView = UIView()
  private let liveLabel = UILabel()
  // Connection status indicator on the device subline (in-view header): solid green
  // pip when the computer is connected, red pip + spinner while reconnecting.
  private let connectionDotView = UIView()
  private let connectionSpinner = UIActivityIndicatorView(style: .medium)
  private var messages: [VibeAgentKitChatMessage]
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
  private var changeObserver: NSObjectProtocol?
  private var keyboardObservers: [NSObjectProtocol] = []
  private let bottomEdgeFadeView = UIView()

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

  /// A single centered spinner shown while a session's transcript is loading, instead
  /// of a fake "Loading conversation…" message bubble. Cleared as soon as rows render.
  private let loadingSpinner = VibeAgentArcSpinner()
  /// Centered welcome shown when the conversation is empty (and not loading): the agent
  /// chat surface lands here directly — a fresh chat with a clear "start typing" cue —
  /// rather than a separate history screen. Past sessions stay reachable via the nav
  /// buttons (new chat / menu); this just keeps the blank state from looking broken.
  private let emptyStateView = UIStackView()
  private let emptyStateIcon = UIImageView()
  private let emptyStateTitle = UILabel()
  private let emptyStateSubtitle = UILabel()
  private var loadingTimeout: DispatchWorkItem?
  var isLoadingTranscript = false {
    didSet {
      loadingTimeout?.cancel()
      if isLoadingTranscript {
        // Never spin forever — fall back to the (blank) empty state if nothing lands.
        // A session with no history shouldn't sit on a spinner, so keep this short.
        let work = DispatchWorkItem { [weak self] in self?.isLoadingTranscript = false }
        loadingTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
      }
      updateLoadingOverlay()
    }
  }

  /// Tapping a message's progress row opens the full tool sheet for that message.
  /// Stashed so we know which message's items to present.
  private var progressItemsByMessageId: [String: [VibeAgentKitProgressItem]] = [:]

  /// Message ids whose "Worked · N steps" line is currently expanded inline.
  /// Persists across reloads so a live update doesn't collapse what the user opened.
  private var expandedProgressMessageIds: Set<String> = []

  /// Per-message set of step node-ids whose detail layer is open (the command/result
  /// box, the edit patch, the read file slice). Keyed by message id → node ids; persists
  /// across reloads so a live tick doesn't re-collapse a step the user drilled into.
  private var expandedStepIdsByMessage: [String: Set<String>] = [:]

  /// When each still-streaming turn was first seen as live. The "Working · M:SS" clock
  /// reads from this so it counts up steadily and NEVER restarts as new chunks arrive
  /// (a fresh `Date()` per chunk was what made the timer appear to reset).
  private var streamStartByMessageId: [String: Date] = [:]

  /// Start a fresh conversation with the agent (clears the on-screen transcript and
  /// begins a new, non-resumed task). When nil the trailing "new chat" button is
  /// hidden — set by hosts where a new chat is meaningful (the bridge runtime view).
  var onNewChat: (() -> Void)?

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
    if let nav = navigationController, nav.viewControllers.first !== self {
      nav.popViewController(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  private func configureNewChatButton() {
    guard !isEmbeddedInSwiftUI, !embeddedInChatHost else { return }
    let newChatButton = UIBarButtonItem(
      image: UIImage(systemName: "square.and.pencil"),
      style: .plain,
      target: self,
      action: #selector(newChatTapped)
    )
    newChatButton.accessibilityLabel = "New Chat"

    let pinAction = UIAction(title: "Pin", image: UIImage(systemName: "pin")) { _ in
      // TODO: Pin action
    }
    let filesAction = UIAction(title: "Files", image: UIImage(systemName: "folder")) { _ in
      // TODO: Files action
    }

    let menu = UIMenu(title: "", children: [pinAction, filesAction])
    let menuButton = UIBarButtonItem(
      image: UIImage(systemName: "ellipsis"),
      menu: menu
    )
    menuButton.accessibilityLabel = "Menu"
    navigationItem.rightBarButtonItems = [menuButton, newChatButton]
  }

  @objc private func newChatTapped() {
    // Warn before abandoning a turn that's still generating; otherwise start fresh.
    let isLive = messages.contains { $0.isStreaming || $0.runtime?.status == "running" }
    guard isLive else { startNewChat(); return }
    let alert = UIAlertController(
      title: "Start a new chat?",
      message: "A response is still generating. It'll keep running on your computer, but this view will switch to a fresh conversation.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "New Chat", style: .destructive) { [weak self] _ in
      self?.startNewChat()
    })
    present(alert, animated: true)
  }

  private func startNewChat() {
    expandedProgressMessageIds.removeAll()
    expandedStepIdsByMessage.removeAll()
    progressItemsByMessageId.removeAll()
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

    composerView.translatesAutoresizingMaskIntoConstraints = false
    composerView.applyAppearance(appearance)
    composerView.placeholder = inputPlaceholder
    composerView.provider = agentBridgeProvider ?? "codex"
    composerView.onSend = { [weak self] text, options in
      guard let self else { return }
      self.onSend?(text, options, self.composerView.consumePendingAttachments())
    }
    composerView.onAttach = { [weak self] in
      self?.presentImageAttachmentPicker()
    }
    composerView.onHeightChanged = { [weak self] height in
      self?.updateComposerHeight(height, animated: true)
    }
    view.addSubview(composerView)

    progressSheet.translatesAutoresizingMaskIntoConstraints = false
    progressSheet.applyAppearance(appearance)
    progressSheet.isHidden = true
    view.addSubview(progressSheet)

    loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
    loadingSpinner.color = appearance.textSecondary
    loadingSpinner.isHidden = true
    view.addSubview(loadingSpinner)

    setupEmptyState()

    // Pin the feed to the TRUE bottom so messages scroll UNDER the floating composer
    // (Resolo-style, no hard footer line). `updateScrollInsets()` keeps a bottom
    // content inset equal to the composer's covered height so the last bubble clears
    // the pill, and grows it with the keyboard.
    let tableBottomConstraint = tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    // Pin the composer to the true bottom of the screen (NOT the safe-area guide):
    // the composer owns its own bottom inset so the pill floats above the home
    // indicator with no visible strip/edge below it.
    let composerBottomConstraint = composerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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
      progressSheet.topAnchor.constraint(equalTo: view.topAnchor),
      progressSheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      progressSheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      progressSheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      loadingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      loadingSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24.0),
      emptyStateView.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.leadingAnchor, constant: 40.0),
      emptyStateView.trailingAnchor.constraint(
        lessThanOrEqualTo: view.trailingAnchor, constant: -40.0),
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

    // The in-view header is built early (before the table/composer were added), so lift
    // it above the feed and keep the spinner/empty-state on top of it.
    if usesInViewHeader, headerBar.superview === view {
      view.bringSubviewToFront(headerBar)
    }

    indexProgress()
    observeKeyboard()
    observeLiveMessages()
    DispatchQueue.main.async { [weak self] in self?.scrollToBottom(animated: false) }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if usesInViewHeader {
      // The VC draws its own header; keep any host nav bar (incl. a wrapped modal nav)
      // hidden so there's no double bar.
      navigationController?.setNavigationBarHidden(true, animated: false)
    }
    applyNavigationAppearance()
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
      loadingSpinner.color = appearance.textSecondary
      if !isEmbeddedInSwiftUI {
        applyNavigationAppearance()
      }
      updateBottomEdgeFade()
      updateEmptyState()
      tableView.reloadData()
    }
  }

  // MARK: Live updates

  /// Replace the rendered messages (e.g. when the agent stream advances). Cheap
  /// reload is fine here — the surface is single-task and short.
  func setMessages(_ newMessages: [VibeAgentKitChatMessage]) {
    guard newMessages != messages else { return }
    let wasNearBottom = isNearBottom()
    let oldIds = messages.map(\.id)
    messages = newMessages
    // Real rows arrived → drop the centered loading spinner.
    if !newMessages.isEmpty { isLoadingTranscript = false }
    trackStreamStarts(newMessages)
    indexProgress()
    updateNavigationLiveState()
    updateLoadingOverlay()

    // A pure append (new turns pushed onto the end — the typical "send") animates the
    // new rows in and scrolls up, matching Resolo's push-in feel. Anything else
    // (streaming edits to existing rows, replacements, reorders) falls back to a plain
    // reload so the streaming label and bubble geometry stay correct.
    let newIds = newMessages.map(\.id)
    let isPureAppend =
      newIds.count > oldIds.count && Array(newIds.prefix(oldIds.count)) == oldIds
    if isPureAppend, tableView.window != nil, tableView.numberOfRows(inSection: 0) == oldIds.count {
      let inserted = (oldIds.count..<newIds.count).map { IndexPath(row: $0, section: 0) }
      tableView.performBatchUpdates {
        tableView.insertRows(at: inserted, with: .fade)
      } completion: { [weak self] _ in
        if wasNearBottom { self?.scrollToBottom(animated: true) }
      }
    } else {
      tableView.reloadData()
      if wasNearBottom { scrollToBottom(animated: true) }
    }
  }

  private func observeLiveMessages() {
    guard messagesProvider != nil else { return }
    changeObserver = NotificationCenter.default.addObserver(
      forName: ChatEngine.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.refreshFromProvider()
    }
  }

  private func refreshFromProvider() {
    guard let messagesProvider else { return }
    let next = messagesProvider()
    guard !next.isEmpty else { return }
    setMessages(next)
  }

  private func configureNavigationTitle() {
    // The embedded (profile) path gets its header from the SwiftUI NavigationStack
    // toolbar; only the standalone/chat presentations build the in-view header.
    guard usesInViewHeader else { return }
    buildInViewHeader()
  }

  /// Build the VC's own header bar. The app hides the system nav bar (custom chat
  /// headers), so pushing this VC there left it header-less; this restores a header
  /// showing the model (center, tappable) + connected device beneath.
  private func buildInViewHeader() {
    navigationController?.setNavigationBarHidden(true, animated: false)

    headerBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(headerBar)

    headerBlur.translatesAutoresizingMaskIntoConstraints = false
    headerBlur.isUserInteractionEnabled = false
    headerBar.addSubview(headerBlur)

    headerSeparator.translatesAutoresizingMaskIntoConstraints = false
    headerBar.addSubview(headerSeparator)

    let symbol = { (name: String, pt: CGFloat, weight: UIImage.SymbolWeight) in
      UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pt, weight: weight))
    }

    headerBackButton.translatesAutoresizingMaskIntoConstraints = false
    headerBackButton.setImage(symbol("chevron.left", 17, .semibold), for: .normal)
    headerBackButton.accessibilityLabel = "Back"
    headerBackButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    headerBar.addSubview(headerBackButton)

    var modelCfg = UIButton.Configuration.plain()
    modelCfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
    modelCfg.imagePlacement = .trailing
    modelCfg.imagePadding = 4
    modelCfg.image = symbol("chevron.up.chevron.down", 10, .semibold)
    headerModelButton.configuration = modelCfg
    headerModelButton.showsMenuAsPrimaryAction = true
    headerModelButton.translatesAutoresizingMaskIntoConstraints = false
    headerModelButton.accessibilityLabel = "Model and run options"

    // Connection pip + spinner sit at the LEFT of the device line.
    connectionDotView.layer.cornerRadius = 3
    connectionDotView.layer.cornerCurve = .continuous
    connectionDotView.translatesAutoresizingMaskIntoConstraints = false
    connectionSpinner.translatesAutoresizingMaskIntoConstraints = false
    connectionSpinner.hidesWhenStopped = true
    connectionSpinner.transform = CGAffineTransform(scaleX: 0.62, y: 0.62)

    subtitleLabel.font = UIFont.systemFont(ofSize: 11.5, weight: .medium)
    subtitleLabel.textAlignment = .left
    subtitleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let deviceRow = UIStackView(arrangedSubviews: [connectionDotView, connectionSpinner, subtitleLabel])
    deviceRow.axis = .horizontal
    deviceRow.alignment = .center
    deviceRow.spacing = 5

    // The model is the prominent centered title; the device + connection pip sit beneath
    // it. Keeping the model on its own row (no inline accessories) means toggling the
    // connection state never shifts the model off-center.
    let centerStack = UIStackView(arrangedSubviews: [headerModelButton, deviceRow])
    centerStack.axis = .vertical
    centerStack.alignment = .center
    centerStack.spacing = 1
    centerStack.translatesAutoresizingMaskIntoConstraints = false
    headerBar.addSubview(centerStack)

    headerNewChatButton.translatesAutoresizingMaskIntoConstraints = false
    headerNewChatButton.setImage(symbol("square.and.pencil", 16, .regular), for: .normal)
    headerNewChatButton.accessibilityLabel = "New Chat"
    headerNewChatButton.addTarget(self, action: #selector(newChatTapped), for: .touchUpInside)
    headerBar.addSubview(headerNewChatButton)

    headerMenuButton.translatesAutoresizingMaskIntoConstraints = false
    headerMenuButton.setImage(symbol("ellipsis", 16, .regular), for: .normal)
    headerMenuButton.accessibilityLabel = "Menu"
    headerMenuButton.showsMenuAsPrimaryAction = true
    headerMenuButton.menu = UIMenu(children: [
      UIAction(title: "Pin", image: UIImage(systemName: "pin")) { _ in },
      UIAction(title: "Files", image: UIImage(systemName: "folder")) { _ in },
    ])
    headerBar.addSubview(headerMenuButton)

    let heightC = headerBar.heightAnchor.constraint(equalToConstant: 52)
    headerHeightConstraint = heightC

    // Center the title block, but let it yield to the leading/trailing button bounds so a
    // long model + device line never forces an ambiguous break that shoves it off-center.
    let centerX = centerStack.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor)
    centerX.priority = .defaultHigh

    NSLayoutConstraint.activate([
      headerBar.topAnchor.constraint(equalTo: view.topAnchor),
      headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      heightC,

      headerBlur.topAnchor.constraint(equalTo: headerBar.topAnchor),
      headerBlur.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
      headerBlur.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
      headerBlur.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),

      headerSeparator.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
      headerSeparator.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
      headerSeparator.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),
      headerSeparator.heightAnchor.constraint(equalToConstant: 0.5),

      headerBackButton.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 8),
      headerBackButton.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: -7),
      headerBackButton.widthAnchor.constraint(equalToConstant: 38),
      headerBackButton.heightAnchor.constraint(equalToConstant: 38),

      headerMenuButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -10),
      headerMenuButton.centerYAnchor.constraint(equalTo: headerBackButton.centerYAnchor),
      headerMenuButton.widthAnchor.constraint(equalToConstant: 34),
      headerMenuButton.heightAnchor.constraint(equalToConstant: 34),

      headerNewChatButton.trailingAnchor.constraint(equalTo: headerMenuButton.leadingAnchor, constant: -4),
      headerNewChatButton.centerYAnchor.constraint(equalTo: headerBackButton.centerYAnchor),
      headerNewChatButton.widthAnchor.constraint(equalToConstant: 34),
      headerNewChatButton.heightAnchor.constraint(equalToConstant: 34),

      centerX,
      centerStack.centerYAnchor.constraint(equalTo: headerBackButton.centerYAnchor),
      centerStack.leadingAnchor.constraint(
        greaterThanOrEqualTo: headerBackButton.trailingAnchor, constant: 8),
      centerStack.trailingAnchor.constraint(
        lessThanOrEqualTo: headerNewChatButton.leadingAnchor, constant: -8),

      connectionDotView.widthAnchor.constraint(equalToConstant: 6),
      connectionDotView.heightAnchor.constraint(equalToConstant: 6),
    ])

    selectionObserver = NotificationCenter.default.addObserver(
      forName: AgentBridgeSelectionStore.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.updateHeaderTexts() }

    applyNavigationAppearance()
    updateHeaderTexts()
    updateNavigationLiveState()
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
    var cfg = headerModelButton.configuration ?? UIButton.Configuration.plain()
    var titleAttributes = AttributeContainer()
    titleAttributes.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    cfg.attributedTitle = AttributedString(modelTitle, attributes: titleAttributes)
    headerModelButton.configuration = cfg
    headerModelButton.menu = runOptionsMenu()

    // Compact device name; the connection state is shown by the pip/spinner, not text.
    let device = (deviceLabel?.isEmpty == false) ? deviceLabel : AgentPairingService.lastDeviceLabel
    let connected = (deviceLabel != nil) ? deviceConnected : AgentPairingService.lastConnected
    let deviceText = (device?.isEmpty == false) ? device : runtimeSubtitle
    subtitleLabel.text = deviceText
    let hasDevice = (deviceText ?? "").isEmpty == false
    subtitleLabel.isHidden = !hasDevice
    updateConnectionIndicator(connected: connected, hasDevice: hasDevice)
  }

  /// Green pip when the computer is connected; red pip + spinner while reconnecting.
  private func updateConnectionIndicator(connected: Bool, hasDevice: Bool) {
    guard usesInViewHeader else { return }
    connectionDotView.isHidden = !hasDevice
    if connected {
      connectionDotView.backgroundColor = UIColor.systemGreen
      connectionSpinner.stopAnimating()
    } else {
      connectionDotView.backgroundColor = UIColor.systemRed
      if hasDevice {
        connectionSpinner.startAnimating()
      } else {
        connectionSpinner.stopAnimating()
      }
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

  private func applyNavigationAppearance() {
    liveDotView.backgroundColor = UIColor.systemGreen
    liveLabel.textColor = UIColor.systemGreen
    connectionSpinner.color = appearance.textSecondary
    subtitleLabel.textColor = appearance.textSecondary

    if usesInViewHeader {
      headerBar.backgroundColor = .clear
      headerSeparator.backgroundColor = appearance.textSecondary.withAlphaComponent(0.14)
      headerBackButton.tintColor = appearance.text
      headerNewChatButton.tintColor = appearance.text
      headerMenuButton.tintColor = appearance.text
      headerModelButton.tintColor = appearance.text
      var cfg = headerModelButton.configuration ?? .plain()
      cfg.baseForegroundColor = appearance.text
      headerModelButton.configuration = cfg
      return
    }

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
    // In-view header: the model can change as runs report it, so refresh the header
    // (model title + connection pip) whenever the message set advances.
    if usesInViewHeader {
      updateHeaderTexts()
      return
    }
    let isLive = messages.contains { message in
      message.isStreaming || message.runtime?.status == "running"
    }
    liveDotView.isHidden = !isLive
    liveLabel.isHidden = !isLive
    subtitleLabel.isHidden = runtimeSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func updateComposerHeight(_ height: CGFloat, animated: Bool) {
    composerHeightConstraint?.constant = height
    let changes = { self.view.layoutIfNeeded() }
    if animated {
      UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: changes)
    } else {
      changes()
    }
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
  private static func sealedImageBlob(from image: UIImage) -> String? {
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
    let center = NotificationCenter.default
    keyboardObservers.append(center.addObserver(
      forName: UIResponder.keyboardWillChangeFrameNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      self?.handleKeyboard(note)
    })
    keyboardObservers.append(center.addObserver(
      forName: UIResponder.keyboardWillHideNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      self?.handleKeyboard(note)
    })
  }

  private func handleKeyboard(_ note: Notification) {
    guard
      let window = view.window,
      let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else { return }
    let endFrameInView = view.convert(endFrame, from: window.screen.coordinateSpace)
    let overlap = max(0, view.bounds.maxY - endFrameInView.minY)
    // The composer is pinned to view.bottomAnchor; lift it by exactly the keyboard
    // overlap. When the keyboard hides (overlap 0) it returns to the bottom, where
    // it re-applies its own home-indicator inset internally.
    composerBottomConstraint?.constant = -overlap
    let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
      self.view.layoutIfNeeded()
      if self.isNearBottom() { self.scrollToBottom(animated: false) }
    }
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
    messages.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let message = messages[indexPath.row]
    // A /compact summary is a centered, collapsible divider — its own cell type, not a
    // bubble. The expand state reuses the per-message progress-expand set.
    if message.isCompactionSummary {
      let cell = tableView.dequeueReusableCell(
        withIdentifier: VibeAgentKitCompactionCell.reuseIdentifier,
        for: indexPath
      ) as! VibeAgentKitCompactionCell
      cell.backgroundColor = .clear
      cell.onToggle = { [weak self] in self?.toggleCompaction(for: message.id) }
      cell.configure(
        text: message.text,
        expanded: expandedProgressMessageIds.contains(message.id),
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
    cell.onRuntimeTap = { [weak self] runtime in self?.presentRuntime(runtime) }
    cell.onStepTap = { [weak self] nodeId in self?.presentStepDetail(messageId: message.id, nodeId: nodeId) }
    cell.configure(
      message: message,
      appearance: appearance,
      regeneratePrompt: regeneratePrompt,
      showsActions: false,
      isProgressExpanded: expandedProgressMessageIds.contains(message.id),
      expandedStepIds: expandedStepIdsByMessage[message.id] ?? [],
      streamingStartDate: message.isStreaming ? streamStartByMessageId[message.id] : nil
    )
    return cell
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
    guard indexPath.row < messages.count else { return nil }
    let message = messages[indexPath.row]
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

  // MARK: Progress (inline expand)

  // Tapping "Worked · N steps" reveals/hides that turn's step list inline, in the
  // bubble (Claude-Code style). The expanded set persists across reloads, and the
  // height change animates via a no-op batch update after reconfiguring the cell.
  private func toggleProgress(for messageId: String) {
    if expandedProgressMessageIds.contains(messageId) {
      expandedProgressMessageIds.remove(messageId)
    } else {
      expandedProgressMessageIds.insert(messageId)
    }
    guard let row = messages.firstIndex(where: { $0.id == messageId }) else { return }
    let indexPath = IndexPath(row: row, section: 0)
    // Reconfigure the visible cell in place (cheap, idempotent), then let the
    // table animate to its new height. If the cell isn't on screen the set is
    // already updated, so cellForRowAt renders it expanded when it scrolls in.
    if let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell {
      cell.configure(
        message: messages[row],
        appearance: appearance,
        regeneratePrompt: regeneratePrompt,
        showsActions: false,
        isProgressExpanded: expandedProgressMessageIds.contains(messageId),
        expandedStepIds: expandedStepIdsByMessage[messageId] ?? [],
        streamingStartDate: messages[row].isStreaming ? streamStartByMessageId[messageId] : nil
      )
    }
    animateExpansion(anchorRow: indexPath)
  }

  /// Animate a cell's height change without the rest of the list jumping. Self-sizing
  /// rows + `performBatchUpdates` can lurch when off-screen heights are re-estimated;
  /// we pin the tapped row's top to its current on-screen position, let the table
  /// re-measure, then restore the offset so the detail simply unfolds downward (and
  /// folds back up) with everything above it held still.
  private func animateExpansion(anchorRow indexPath: IndexPath) {
    let beforeRect = tableView.rectForRow(at: indexPath)
    let distanceFromTop = beforeRect.minY - tableView.contentOffset.y
    tableView.performBatchUpdates(nil, completion: nil)
    let afterRect = tableView.rectForRow(at: indexPath)
    let minOffset = -tableView.adjustedContentInset.top
    let maxOffset = max(
      minOffset,
      tableView.contentSize.height - tableView.bounds.height
        + tableView.adjustedContentInset.bottom)
    let targetY = min(max(afterRect.minY - distanceFromTop, minOffset), maxOffset)
    tableView.setContentOffset(CGPoint(x: tableView.contentOffset.x, y: targetY), animated: false)
  }

  // Tapping a /compact divider reveals or hides the kept summary, in place — same
  // anchored unfold as the other toggles, reusing the per-message expand set.
  private func toggleCompaction(for messageId: String) {
    if expandedProgressMessageIds.contains(messageId) {
      expandedProgressMessageIds.remove(messageId)
    } else {
      expandedProgressMessageIds.insert(messageId)
    }
    guard let row = messages.firstIndex(where: { $0.id == messageId }) else { return }
    let indexPath = IndexPath(row: row, section: 0)
    if let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitCompactionCell {
      cell.configure(
        text: messages[row].text,
        expanded: expandedProgressMessageIds.contains(messageId),
        appearance: appearance
      )
    }
    animateExpansion(anchorRow: indexPath)
  }

  // Tapping a single step row (a command, an edit, a read) opens its full detail in a
  // bottom SHEET — the command + result code box, the edit patch, the read file slice —
  // rather than unfolding inline (which pushed the rest of the turn around). The sheet
  // is self-contained and dismissible, so drilling into a step never disturbs the feed.
  private func presentStepDetail(messageId: String, nodeId: String) {
    guard
      let items = progressItemsByMessageId[messageId],
      let item = items.first(where: { ($0.nodeId ?? $0.label) == nodeId })
    else { return }
    let controller = VibeAgentKitStepDetailViewController(item: item, appearance: appearance)
    let nav = UINavigationController(rootViewController: controller)
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 22.0
    }
    present(nav, animated: true)
  }

  private func presentRuntime(_ runtime: ChatListRow.AgentRuntimeSummary) {
    guard runtime.diff?.files.isEmpty == false else { return }
    let controller = AgentRuntimeFilesViewController(
      runtime: runtime,
      appearance: .fallback,
      chatId: agentBridgeChatId,
      provider: agentBridgeProvider ?? runtime.provider
    )
    // The history surface isn't inside a UINavigationController, so a plain push
    // would silently no-op. Push when we can; otherwise present a modal nav (the
    // file→diff drill-down then works because it now has a nav stack).
    if let nav = navigationController {
      nav.pushViewController(controller, animated: true)
    } else {
      controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
        primaryAction: UIAction(title: "Done") { [weak self] _ in self?.dismiss(animated: true) }
      )
      let nav = UINavigationController(rootViewController: controller)
      present(nav, animated: true)
    }
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
    emptyStateIcon.image = UIImage(systemName: "sparkles")?.withRenderingMode(.alwaysTemplate)
    emptyStateIcon.tintColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.55)

    emptyStateTitle.numberOfLines = 0
    emptyStateTitle.textAlignment = .center
    emptyStateTitle.font = UIFont.systemFont(ofSize: 19.0, weight: .semibold)
    emptyStateTitle.textColor = appearance.text

    emptyStateSubtitle.numberOfLines = 0
    emptyStateSubtitle.textAlignment = .center
    emptyStateSubtitle.font = UIFont.systemFont(ofSize: 14.5, weight: .regular)
    emptyStateSubtitle.textColor = appearance.textSecondary

    emptyStateView.addArrangedSubview(emptyStateIcon)
    emptyStateView.setCustomSpacing(14.0, after: emptyStateIcon)
    emptyStateView.addArrangedSubview(emptyStateTitle)
    emptyStateView.addArrangedSubview(emptyStateSubtitle)
    view.addSubview(emptyStateView)
    NSLayoutConstraint.activate([
      emptyStateIcon.widthAnchor.constraint(equalToConstant: 34.0),
      emptyStateIcon.heightAnchor.constraint(equalToConstant: 34.0),
    ])
  }

  private func updateEmptyState() {
    // The Claude/Codex bridge view is a SESSION surface: it loads a specific
    // conversation's history (or live run), so a "Start a new chat" welcome here just
    // fought the history load and flashed over the spinner. Only the standalone agent
    // surface shows the welcome; the bridge view shows the spinner, then the transcript.
    let show = messages.isEmpty && !isLoadingTranscript && !isEmbeddedInSwiftUI
    emptyStateView.isHidden = !show
    guard show else { return }
    let name = agentDisplayName
    emptyStateTitle.text = "Start a new chat with \(name)"
    emptyStateSubtitle.text = "Ask a question or describe a task — \(name) runs it on your computer and the reply streams back here."
    emptyStateIcon.tintColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.55)
    emptyStateTitle.textColor = appearance.text
    emptyStateSubtitle.textColor = appearance.textSecondary
  }

  // MARK: Scroll helpers

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if usesInViewHeader {
      let h = view.safeAreaInsets.top + 52
      if headerHeightConstraint?.constant != h { headerHeightConstraint?.constant = h }
      // Tuck the feed just under the blurred header so the first row clears it.
      let topInset = max(12, h - 4)
      if abs(tableView.contentInset.top - topInset) > 0.5 {
        tableView.contentInset.top = topInset
        tableView.verticalScrollIndicatorInsets.top = h
      }
    }
    updateScrollInsets()
    updateBottomEdgeFadeFrame()
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
  private func updateScrollInsets() {
    let covered = max(0, view.bounds.maxY - composerView.frame.minY)
    // The table reaches the screen bottom, so its automatic safe-area inset already
    // covers the home indicator; only add the part above it, plus a small gap.
    let bottom = max(12, covered - view.safeAreaInsets.bottom + 8)
    guard abs(tableView.contentInset.bottom - bottom) > 0.5 else { return }
    let wasNearBottom = isNearBottom()
    tableView.contentInset.bottom = bottom
    tableView.verticalScrollIndicatorInsets.bottom = bottom
    if wasNearBottom { scrollToBottom(animated: false) }
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
    arcLayer.lineWidth = 3
    layer.addSublayer(arcLayer)
  }

  required init?(coder: NSCoder) { return nil }

  override var intrinsicContentSize: CGSize { CGSize(width: 30, height: 30) }

  override func layoutSubviews() {
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

private final class VibeAgentRuntimeComposerView: UIView, UITextViewDelegate {
  var onSend: ((String, AgentBridgeRunOptions) -> Void)? {
    didSet { updateSendState() }
  }
  var onHeightChanged: ((CGFloat) -> Void)?
  /// Tapped the "+" — the controller presents an image picker and stages the result
  /// via `addAttachment(blob:)`. The composer can't present, so it delegates up.
  var onAttach: (() -> Void)?
  /// Encrypted image blobs staged to ride along with the next send.
  private var pendingAttachmentBlobs: [String] = []
  var placeholder: String = "Ask Codex" {
    didSet { placeholderLabel.text = placeholder }
  }
  var provider: String = "codex" {
    didSet { refreshOptions() }
  }

  /// The visible rounded "pill". `self` is a transparent container that extends to
  /// the very bottom of the screen (ignoring the safe-area inset) so there is no
  /// edge/strip below the input; the pill is inset above the home indicator.
  private let pillView = UIView()
  private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
  private let overlayView = UIView()
  private let textView = UITextView()
  private let placeholderLabel = UILabel()
  private let plusButton = UIButton(type: .system)
  /// Model / reasoning picker chip — shown only in the expanded state.
  private let optionsChip = UIButton(type: .system)
  private let micButton = UIButton(type: .system)
  private let sendButton = UIButton(type: .system)
  private var appearance: VibeAgentKitChatAppearance = .fallback

  /// Compact (idle) vs expanded (focused / has text). Compact is a short capsule
  /// with just "+ … mic"; expanded grows and reveals the model chip + send button.
  private var isExpanded = false
  private var compactConstraints: [NSLayoutConstraint] = []
  private var expandedConstraints: [NSLayoutConstraint] = []
  private var pillBottomConstraint: NSLayoutConstraint!
  private var pillLeadingConstraint: NSLayoutConstraint!
  private var pillTrailingConstraint: NSLayoutConstraint!

  private let compactPillHeight: CGFloat = 46
  private let bottomGap: CGFloat = 8
  private let pagePadding: CGFloat = 14

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

  /// Total height the host should give this view: the pill plus the inset that
  /// keeps the pill above the home indicator. Because `self` extends to the screen
  /// bottom, `safeAreaInsets.bottom` here is exactly the home-indicator height (and
  /// becomes 0 once the keyboard covers it, so the pill hugs the keyboard).
  var preferredHeight: CGFloat {
    pillHeightForState() + safeAreaInsets.bottom + bottomGap
  }

  private func pillHeightForState() -> CGFloat {
    guard isExpanded else { return compactPillHeight }
    let width = measurementWidth()
    let textWidth = max(40, width - pagePadding * 2 - 32)
    let fit = textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
    let textHeight = min(max(ceil(fit.height), 30), 124)
    // topPad(6) + text + gap(4) + controls row (40pt button + 6pt bottom inset).
    return min(max(6 + textHeight + 4 + 46, 96), 220)
  }

  private func measurementWidth() -> CGFloat {
    if bounds.width > 0 { return bounds.width }
    return window?.bounds.width ?? UIScreen.main.bounds.width
  }

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
  }

  func applyAppearance(_ appearance: VibeAgentKitChatAppearance) {
    self.appearance = appearance
    backgroundColor = .clear
    // Neutral pill — a light tint over the `blurView` so the glass effect is visible
    // through it (Resolo-style). Low alpha lets the blur dominate; the tint only
    // gives the pill a slight directional color, not a solid fill.
    let fill = appearance.isDark
      ? UIColor(white: 0.10, alpha: 0.55)
      : UIColor(white: 0.98, alpha: 0.60)
    let stroke = appearance.isDark
      ? UIColor(white: 1.0, alpha: 0.08)
      : UIColor(white: 0.0, alpha: 0.08)
    overlayView.backgroundColor = fill
    pillView.layer.borderColor = stroke.cgColor
    textView.textColor = appearance.text
    placeholderLabel.textColor = appearance.textTertiary
    [plusButton, micButton].forEach { $0.tintColor = appearance.text }
    refreshOptions()
    updateAttachmentIndicator()
    updateSendState()
  }

  private func configure() {
    backgroundColor = .clear

    pillView.translatesAutoresizingMaskIntoConstraints = false
    pillView.clipsToBounds = true
    pillView.layer.cornerRadius = 22
    pillView.layer.cornerCurve = .continuous
    pillView.layer.borderWidth = 1
    addSubview(pillView)

    blurView.translatesAutoresizingMaskIntoConstraints = false
    pillView.addSubview(blurView)

    overlayView.translatesAutoresizingMaskIntoConstraints = false
    pillView.addSubview(overlayView)

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.backgroundColor = .clear
    textView.font = UIFont.systemFont(ofSize: 17, weight: .regular)
    textView.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
    textView.textContainer.lineFragmentPadding = 0
    textView.isScrollEnabled = true
    textView.returnKeyType = .default
    textView.delegate = self
    pillView.addSubview(textView)

    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    placeholderLabel.text = placeholder
    placeholderLabel.font = UIFont.systemFont(ofSize: 17, weight: .regular)
    placeholderLabel.numberOfLines = 1
    pillView.addSubview(placeholderLabel)

    configureIconButton(plusButton, systemName: "plus")
    plusButton.addTarget(self, action: #selector(handlePlus), for: .touchUpInside)
    configureOptionsChip()
    configureIconButton(micButton, systemName: "mic")
    // Mic and send share one glyph size so the trailing controls read as a balanced
    // pair. Preferred config persists across the dictation icon swaps.
    let controlGlyph = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
    micButton.setPreferredSymbolConfiguration(controlGlyph, forImageIn: .normal)
    micButton.addTarget(self, action: #selector(handleMic), for: .touchUpInside)
    configureIconButton(sendButton, systemName: "arrow.up")
    sendButton.setPreferredSymbolConfiguration(controlGlyph, forImageIn: .normal)
    sendButton.backgroundColor = UIColor.white.withAlphaComponent(0.20)
    sendButton.layer.cornerRadius = 20
    sendButton.layer.cornerCurve = .continuous
    sendButton.addTarget(self, action: #selector(handleSend), for: .touchUpInside)
    [plusButton, optionsChip, micButton, sendButton].forEach(pillView.addSubview)

    // `self` extends to the screen bottom; the pill is inset above the home
    // indicator by `safeAreaInsets.bottom + bottomGap` (updated in
    // `safeAreaInsetsDidChange`), so there is never a visible strip/edge below it.
    pillBottomConstraint = pillView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomGap)
    pillLeadingConstraint = pillView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pagePadding)
    pillTrailingConstraint = pillView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pagePadding)
    NSLayoutConstraint.activate([
      pillView.topAnchor.constraint(equalTo: topAnchor),
      pillLeadingConstraint,
      pillTrailingConstraint,
      pillBottomConstraint,

      blurView.topAnchor.constraint(equalTo: pillView.topAnchor),
      blurView.leadingAnchor.constraint(equalTo: pillView.leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: pillView.trailingAnchor),
      blurView.bottomAnchor.constraint(equalTo: pillView.bottomAnchor),
      overlayView.topAnchor.constraint(equalTo: pillView.topAnchor),
      overlayView.leadingAnchor.constraint(equalTo: pillView.leadingAnchor),
      overlayView.trailingAnchor.constraint(equalTo: pillView.trailingAnchor),
      overlayView.bottomAnchor.constraint(equalTo: pillView.bottomAnchor),

      plusButton.widthAnchor.constraint(equalToConstant: 40),
      plusButton.heightAnchor.constraint(equalToConstant: 40),
      micButton.widthAnchor.constraint(equalToConstant: 40),
      micButton.heightAnchor.constraint(equalToConstant: 40),
      sendButton.widthAnchor.constraint(equalToConstant: 40),
      sendButton.heightAnchor.constraint(equalToConstant: 40),
      optionsChip.heightAnchor.constraint(equalToConstant: 32),
    ])

    buildStateConstraints()
    applyState()
    applyAppearance(.fallback)
  }

  /// Build (but don't activate) the two layouts. `applyState` toggles between them.
  ///   • Compact: a single short capsule row → "+  text …  mic".
  ///   • Expanded: text on top with a control row (+, model chip, mic, send) below.
  private func buildStateConstraints() {
    compactConstraints = [
      plusButton.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: 6),
      plusButton.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
      micButton.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -6),
      micButton.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
      textView.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 2),
      textView.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -2),
      textView.topAnchor.constraint(equalTo: pillView.topAnchor),
      textView.bottomAnchor.constraint(equalTo: pillView.bottomAnchor),
      placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
      placeholderLabel.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
    ]

    expandedConstraints = [
      textView.topAnchor.constraint(equalTo: pillView.topAnchor, constant: 6),
      textView.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: 16),
      textView.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -16),
      textView.bottomAnchor.constraint(equalTo: plusButton.topAnchor, constant: -2),
      plusButton.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: 6),
      plusButton.bottomAnchor.constraint(equalTo: pillView.bottomAnchor, constant: -6),
      optionsChip.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 4),
      optionsChip.centerYAnchor.constraint(equalTo: plusButton.centerYAnchor),
      optionsChip.trailingAnchor.constraint(lessThanOrEqualTo: micButton.leadingAnchor, constant: -8),
      sendButton.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -6),
      sendButton.bottomAnchor.constraint(equalTo: pillView.bottomAnchor, constant: -6),
      micButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -4),
      micButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
      placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
      placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 2),
    ]
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Capsule when compact, rounded-rect once it grows.
    pillView.layer.cornerRadius = min(pillView.bounds.height / 2, 22)
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    pillBottomConstraint.constant = -(safeAreaInsets.bottom + bottomGap)
    onHeightChanged?(preferredHeight)
  }

  private func configureIconButton(_ button: UIButton, systemName: String) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setImage(UIImage(systemName: systemName), for: .normal)
    button.imageView?.contentMode = .scaleAspectFit
    button.tintColor = .white
  }

  private func configureOptionsChip() {
    optionsChip.translatesAutoresizingMaskIntoConstraints = false
    optionsChip.showsMenuAsPrimaryAction = true
    optionsChip.changesSelectionAsPrimaryAction = false
    optionsChip.accessibilityLabel = "Model and reasoning"
    var cfg = UIButton.Configuration.plain()
    cfg.image = UIImage(
      systemName: "chevron.down",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    cfg.imagePlacement = .trailing
    cfg.imagePadding = 5
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 10)
    cfg.titleLineBreakMode = .byTruncatingTail
    optionsChip.configuration = cfg
    // Let the chip truncate instead of pushing the mic/send off the trailing edge.
    optionsChip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    optionsChip.setContentHuggingPriority(.required, for: .horizontal)
  }

  // MARK: Compact ↔ expanded

  /// Toggle the active layout. Height changes are driven through `onHeightChanged`
  /// so the host animates the composer and message list together.
  private func applyState() {
    let padding: CGFloat = isExpanded ? 14 : 20
    pillLeadingConstraint.constant = padding
    pillTrailingConstraint.constant = -padding

    NSLayoutConstraint.deactivate(isExpanded ? compactConstraints : expandedConstraints)
    NSLayoutConstraint.activate(isExpanded ? expandedConstraints : compactConstraints)
    optionsChip.isHidden = !isExpanded
    sendButton.isHidden = !isExpanded
    onHeightChanged?(preferredHeight)
    updateSendState()
  }

  private func setExpanded(_ expanded: Bool) {
    guard expanded != isExpanded else { return }
    isExpanded = expanded
    applyState()
  }

  /// Refill the composer with an existing message's text for editing — expand and
  /// focus it so the user can revise and resend (used by the hold menu's "Edit").
  func beginEditing(with text: String) {
    textView.text = text
    placeholderLabel.isHidden = !text.isEmpty
    setExpanded(true)
    textViewDidChange(textView)
    textView.becomeFirstResponder()
  }

  @objc private func handleSend() {
    stopDictation()
    let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, onSend != nil else { return }
    let options = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
    textView.text = ""
    textViewDidChange(textView)
    onSend?(text, options)
  }

  // MARK: Image attachments

  @objc private func handlePlus() {
    onAttach?()
  }

  /// Stage an encrypted image blob to ride along with the next send. The "+" button
  /// reflects how many are queued so the user knows an image is attached.
  func addAttachment(blob: String) {
    pendingAttachmentBlobs.append(blob)
    updateAttachmentIndicator()
  }

  /// Hand the staged blobs to the caller and clear them (called at send time).
  func consumePendingAttachments() -> [String] {
    let blobs = pendingAttachmentBlobs
    pendingAttachmentBlobs.removeAll()
    updateAttachmentIndicator()
    return blobs
  }

  private func updateAttachmentIndicator() {
    let count = pendingAttachmentBlobs.count
    plusButton.setImage(
      UIImage(systemName: count > 0 ? "photo.badge.plus.fill" : "plus"), for: .normal)
    plusButton.tintColor = count > 0 ? .systemBlue : appearance.text
    plusButton.accessibilityValue = count > 0 ? "\(count) image(s) attached" : nil
  }

  // MARK: Voice dictation

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
    micButton.setImage(UIImage(systemName: isDictating ? "mic.fill" : "mic"), for: .normal)
    micButton.tintColor = isDictating ? .systemRed : appearance.text
  }

  func textViewDidBeginEditing(_ textView: UITextView) {
    setExpanded(true)
  }

  func textViewDidEndEditing(_ textView: UITextView) {
    // Collapse back to the compact capsule only when there's nothing to keep.
    if textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      pendingAttachmentBlobs.isEmpty {
      setExpanded(false)
    }
  }

  func textViewDidChange(_ textView: UITextView) {
    placeholderLabel.isHidden = !textView.text.isEmpty
    if !textView.text.isEmpty { setExpanded(true) }
    if isExpanded { onHeightChanged?(preferredHeight) }
    updateSendState()
  }

  private func updateSendState() {
    let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let enabled = hasText && onSend != nil
    sendButton.isEnabled = enabled
    sendButton.tintColor = enabled ? appearance.background : appearance.textSecondary
    sendButton.backgroundColor = enabled ? appearance.text : appearance.textSecondary.withAlphaComponent(0.24)
  }

  /// Rebuild the picker menu AND the chip's label ("<model> · <reasoning>"). Called
  /// whenever the selection or provider changes.
  private func refreshOptions() {
    let selectedOptions = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
    // Each control is its OWN picker (Model / Thinking / Speed) with the live
    // selection shown as the submenu subtitle and a checkmark on the active row, so
    // it's obvious what's actually selected and being sent — not a placeholder.
    let modelActions = modelChoices(for: provider).map { choice in
      UIAction(
        title: choice.title,
        subtitle: choice.subtitle,
        state: choice.value == selectedOptions.model ? .on : .off
      ) { [weak self] _ in
        AgentBridgeSelectionStore.setModel(provider: self?.provider ?? "codex", model: choice.value)
        self?.refreshOptions()
      }
    }

    let thinkingActions = AgentBridgeIntelligenceLevel.allCases.map { level in
      UIAction(
        title: level.title,
        state: selectedOptions.intelligence == level ? .on : .off
      ) { [weak self] _ in
        AgentBridgeSelectionStore.setIntelligence(level)
        self?.refreshOptions()
      }
    }

    let speedActions = AgentBridgeSpeedMode.allCases.map { speed in
      UIAction(
        title: speed.title,
        state: selectedOptions.speed == speed ? .on : .off
      ) { [weak self] _ in
        AgentBridgeSelectionStore.setSpeed(speed)
        self?.refreshOptions()
      }
    }

    optionsChip.menu = UIMenu(
      title: provider.lowercased() == "claude" ? "Claude run options" : "Codex run options",
      children: [
        UIMenu(title: "Model", subtitle: currentModelTitle(selectedOptions), children: modelActions),
        UIMenu(title: "Thinking", subtitle: selectedOptions.intelligence.title, children: thinkingActions),
        UIMenu(title: "Speed", subtitle: selectedOptions.speed.title, children: speedActions),
      ]
    )

    var cfg = optionsChip.configuration ?? .plain()
    var title = AttributedString("\(currentModelTitle(selectedOptions)) · \(selectedOptions.intelligence.title)")
    title.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    title.foregroundColor = appearance.text
    cfg.attributedTitle = title
    cfg.baseForegroundColor = appearance.textSecondary  // chevron tint
    cfg.background.backgroundColor = appearance.isDark
      ? UIColor(white: 1.0, alpha: 0.10)
      : UIColor(white: 0.0, alpha: 0.06)
    cfg.background.cornerRadius = 16
    optionsChip.configuration = cfg
  }

  /// The human label for the currently selected model. When nothing specific is
  /// picked we show "Auto" (the CLI's own default) rather than the bare provider
  /// name, so the chip never reads like an unwired placeholder.
  private func currentModelTitle(_ options: AgentBridgeRunOptions) -> String {
    if let model = options.model {
      if let match = modelChoices(for: provider).first(where: { $0.value == model }) {
        return match.title
      }
      if !model.isEmpty { return model }
    }
    return "Auto"
  }

  private func modelChoices(for provider: String) -> [(title: String, subtitle: String?, value: String?)] {
    switch provider.lowercased() {
    case "claude":
      return [
        ("Auto", "Claude Code default", nil),
        ("Haiku", "Fastest, lightest", "haiku"),
        ("Sonnet", "Balanced", "sonnet"),
        ("Opus", "Most capable", "opus"),
      ]
    default:
      return [
        ("Auto", "Codex default", nil),
        ("GPT-5.5", nil, "gpt-5.5"),
        ("GPT-5.5 Pro", nil, "gpt-5.5-pro"),
        ("GPT-5.4", nil, "gpt-5.4"),
        ("GPT-5.2", nil, "gpt-5.2"),
        ("GPT-5", nil, "gpt-5"),
      ]
    }
  }
}
