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
    VibeAgentKitProgressItem(
      label: chatAgentNodeCompactLabel(node),
      badges: [],
      eventType: "progress",
      recipient: nil,
      platform: nil,
      format: nil,
      messageContent: actionDetailBody(kind: node.kind, detail: detail),
      messagePreview: nil,
      voiceUrl: nil,
      voiceDuration: nil,
      status: node.status,
      isRecording: false,
      recordingStartTime: nil,
      tool: node.kind,
      image: nil,
      itemType: node.kind,
      sourceUrl: nil
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
    let defaultBody = row.isAgentMessage ? (row.plainContent ?? row.text) : row.text
    // /compact summaries render as a distinct mid-chat block (not a user bubble).
    let body = (row.isAgentMessage ? agentSummaryBody(for: row) : nil) ?? defaultBody
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
      isStreaming: row.isAgentMessage && row.isStreamingText,
      isError: row.status == "failed",
      progress: [],
      progressItems: items,
      runtime: row.isAgentMessage ? row.agentRuntime : nil
    )
  }

  /// A /compact summary → a distinct, emoji-free "what happened" block rendered
  /// mid-chat (not a user bubble). Returns nil for ordinary agent messages.
  private static func agentSummaryBody(for row: ChatListRow) -> String? {
    guard row.agentMsgKind == "summary" else { return nil }
    let full = (row.plainContent ?? row.text).trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = String(full.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
    let ellipsis = full.count > 400 ? "…" : ""
    return "## Summary so far\n\n\(preview)\(ellipsis)"
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

final class VibeAgentConversationViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

  private let tableView = UITableView(frame: .zero, style: .plain)
  private let progressSheet = VibeAgentKitAgentProgressSheetView()
  private let composerView = VibeAgentRuntimeComposerView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let liveDotView = UIView()
  private let liveLabel = UILabel()
  private var messages: [VibeAgentKitChatMessage]
  private var appearance: VibeAgentKitChatAppearance
  private let runtimeTitle: String
  private let runtimeSubtitle: String
  private let inputPlaceholder: String
  private let regeneratePrompt: String
  private let messagesProvider: (() -> [VibeAgentKitChatMessage])?
  private let onSend: ((String, AgentBridgeRunOptions) -> Void)?
  private var tableBottomConstraint: NSLayoutConstraint?
  private var composerBottomConstraint: NSLayoutConstraint?
  private var composerHeightConstraint: NSLayoutConstraint?
  private var changeObserver: NSObjectProtocol?
  private var keyboardObservers: [NSObjectProtocol] = []

  /// Tapping a message's progress row opens the full tool sheet for that message.
  /// Stashed so we know which message's items to present.
  private var progressItemsByMessageId: [String: [VibeAgentKitProgressItem]] = [:]

  /// Message ids whose "Worked · N steps" line is currently expanded inline.
  /// Persists across reloads so a live update doesn't collapse what the user opened.
  private var expandedProgressMessageIds: Set<String> = []

  /// Chat + provider context (history surface) so a runtime card can route a
  /// full-file-open request to the user's bridge. Nil in the live agent view.
  var agentBridgeChatId: String?
  var agentBridgeProvider: String? {
    didSet { composerView.provider = agentBridgeProvider ?? "codex" }
  }

  init(
    title: String,
    subtitle: String = "",
    messages: [VibeAgentKitChatMessage],
    regeneratePrompt: String = "",
    inputPlaceholder: String? = nil,
    messagesProvider: (() -> [VibeAgentKitChatMessage])? = nil,
    onSend: ((String, AgentBridgeRunOptions) -> Void)? = nil
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
    keyboardObservers.forEach(NotificationCenter.default.removeObserver)
  }

  @objc func closeTapped() {
    if let nav = navigationController, nav.viewControllers.first !== self {
      nav.popViewController(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    edgesForExtendedLayout = []
    appearance = VibeAgentKitMap.appearance(for: traitCollection)
    view.backgroundColor = appearance.background
    configureNavigationTitle()

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.backgroundColor = appearance.background
    tableView.separatorStyle = .none
    tableView.dataSource = self
    tableView.delegate = self
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 96.0
    tableView.keyboardDismissMode = .interactive
    tableView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
    tableView.register(VibeAgentKitMessageCell.self, forCellReuseIdentifier: VibeAgentKitMessageCell.reuseIdentifier)
    view.addSubview(tableView)

    composerView.translatesAutoresizingMaskIntoConstraints = false
    composerView.applyAppearance(appearance)
    composerView.placeholder = inputPlaceholder
    composerView.provider = agentBridgeProvider ?? "codex"
    composerView.onSend = { [weak self] text, options in
      self?.onSend?(text, options)
    }
    composerView.onHeightChanged = { [weak self] height in
      self?.updateComposerHeight(height, animated: true)
    }
    view.addSubview(composerView)

    progressSheet.translatesAutoresizingMaskIntoConstraints = false
    progressSheet.applyAppearance(appearance)
    progressSheet.isHidden = true
    view.addSubview(progressSheet)

    let tableBottomConstraint = tableView.bottomAnchor.constraint(equalTo: composerView.topAnchor, constant: -8)
    let composerBottomConstraint = composerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
    let composerHeightConstraint = composerView.heightAnchor.constraint(equalToConstant: composerView.preferredHeight)
    self.tableBottomConstraint = tableBottomConstraint
    self.composerBottomConstraint = composerBottomConstraint
    self.composerHeightConstraint = composerHeightConstraint

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableBottomConstraint,
      composerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      composerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      composerBottomConstraint,
      composerHeightConstraint,
      progressSheet.topAnchor.constraint(equalTo: view.topAnchor),
      progressSheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      progressSheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      progressSheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    indexProgress()
    observeKeyboard()
    observeLiveMessages()
    DispatchQueue.main.async { [weak self] in self?.scrollToBottom(animated: false) }
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    if traitCollection.userInterfaceStyle != previous?.userInterfaceStyle {
      appearance = VibeAgentKitMap.appearance(for: traitCollection)
      view.backgroundColor = appearance.background
      tableView.backgroundColor = appearance.background
      progressSheet.applyAppearance(appearance)
      composerView.applyAppearance(appearance)
      applyNavigationAppearance()
      tableView.reloadData()
    }
  }

  // MARK: Live updates

  /// Replace the rendered messages (e.g. when the agent stream advances). Cheap
  /// reload is fine here — the surface is single-task and short.
  func setMessages(_ newMessages: [VibeAgentKitChatMessage]) {
    guard newMessages != messages else { return }
    let wasNearBottom = isNearBottom()
    messages = newMessages
    indexProgress()
    updateNavigationLiveState()
    tableView.reloadData()
    if wasNearBottom { scrollToBottom(animated: true) }
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
    titleLabel.text = runtimeTitle
    titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
    titleLabel.textAlignment = .left
    titleLabel.lineBreakMode = .byTruncatingTail

    subtitleLabel.text = runtimeSubtitle
    subtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
    subtitleLabel.textAlignment = .left
    subtitleLabel.lineBreakMode = .byTruncatingTail

    liveDotView.layer.cornerRadius = 3.5
    liveDotView.layer.cornerCurve = .continuous
    liveLabel.text = "Live"
    liveLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)

    let titleRow = UIStackView(arrangedSubviews: [titleLabel, liveDotView, liveLabel])
    titleRow.axis = .horizontal
    titleRow.alignment = .center
    titleRow.spacing = 6

    let stack = UIStackView(arrangedSubviews: [titleRow, subtitleLabel])
    stack.axis = .vertical
    stack.alignment = .leading
    stack.spacing = 1
    stack.frame = CGRect(x: 0, y: 0, width: 220, height: 38)
    NSLayoutConstraint.activate([
      liveDotView.widthAnchor.constraint(equalToConstant: 7),
      liveDotView.heightAnchor.constraint(equalToConstant: 7),
    ])
    navigationItem.titleView = stack
    applyNavigationAppearance()
    updateNavigationLiveState()
  }

  private func applyNavigationAppearance() {
    titleLabel.textColor = appearance.text
    subtitleLabel.textColor = appearance.textSecondary
    liveDotView.backgroundColor = UIColor.systemGreen
    liveLabel.textColor = UIColor.systemGreen
    let navAppearance = UINavigationBarAppearance()
    navAppearance.configureWithOpaqueBackground()
    navAppearance.backgroundColor = appearance.background
    navAppearance.shadowColor = .clear
    navAppearance.titleTextAttributes = [.foregroundColor: appearance.text]
    navigationController?.navigationBar.standardAppearance = navAppearance
    navigationController?.navigationBar.scrollEdgeAppearance = navAppearance
    navigationController?.navigationBar.compactAppearance = navAppearance
    navigationController?.navigationBar.isTranslucent = false
  }

  private func updateNavigationLiveState() {
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
    composerBottomConstraint?.constant = overlap > 0 ? -(overlap - view.safeAreaInsets.bottom + 8) : -8
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

  // MARK: Table

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    messages.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(
      withIdentifier: VibeAgentKitMessageCell.reuseIdentifier,
      for: indexPath
    ) as! VibeAgentKitMessageCell
    let message = messages[indexPath.row]
    cell.backgroundColor = .clear
    cell.selectionStyle = .none
    cell.onProgressTap = { [weak self] in self?.toggleProgress(for: message.id) }
    cell.onRuntimeTap = { [weak self] runtime in self?.presentRuntime(runtime) }
    cell.configure(
      message: message,
      appearance: appearance,
      regeneratePrompt: regeneratePrompt,
      showsActions: false,
      isProgressExpanded: expandedProgressMessageIds.contains(message.id)
    )
    return cell
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
        isProgressExpanded: expandedProgressMessageIds.contains(messageId)
      )
    }
    tableView.performBatchUpdates(nil, completion: nil)
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

  // MARK: Scroll helpers

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

private final class VibeAgentRuntimeComposerView: UIView, UITextViewDelegate {
  var onSend: ((String, AgentBridgeRunOptions) -> Void)? {
    didSet { updateSendState() }
  }
  var onHeightChanged: ((CGFloat) -> Void)?
  var placeholder: String = "Ask Codex" {
    didSet { placeholderLabel.text = placeholder }
  }
  var provider: String = "codex" {
    didSet { rebuildOptionsMenu() }
  }

  private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
  private let overlayView = UIView()
  private let textView = UITextView()
  private let placeholderLabel = UILabel()
  private let plusButton = UIButton(type: .system)
  private let optionsButton = UIButton(type: .system)
  private let micButton = UIButton(type: .system)
  private let sendButton = UIButton(type: .system)
  private var appearance: VibeAgentKitChatAppearance = .fallback

  var preferredHeight: CGFloat {
    64
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    configure()
  }

  required init?(coder: NSCoder) { return nil }

  func applyAppearance(_ appearance: VibeAgentKitChatAppearance) {
    self.appearance = appearance
    backgroundColor = .clear
    layer.borderColor = appearance.border.withAlphaComponent(0.72).cgColor
    overlayView.backgroundColor = appearance.surface.withAlphaComponent(appearance.isDark ? 0.82 : 0.92)
    textView.textColor = appearance.text
    placeholderLabel.textColor = appearance.textTertiary
    [plusButton, optionsButton, micButton].forEach { button in
      button.tintColor = appearance.text
    }
    updateSendState()
  }

  private func configure() {
    clipsToBounds = true
    layer.cornerRadius = 24
    layer.cornerCurve = .continuous
    layer.borderWidth = 1

    blurView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blurView)

    overlayView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(overlayView)

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.backgroundColor = .clear
    textView.font = UIFont.systemFont(ofSize: 17, weight: .regular)
    textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 8, right: 0)
    textView.textContainer.lineFragmentPadding = 0
    textView.isScrollEnabled = true
    textView.returnKeyType = .default
    textView.delegate = self
    addSubview(textView)

    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    placeholderLabel.text = placeholder
    placeholderLabel.font = UIFont.systemFont(ofSize: 17, weight: .regular)
    placeholderLabel.numberOfLines = 1
    addSubview(placeholderLabel)

    configureIconButton(plusButton, systemName: "plus")
    configureIconButton(optionsButton, systemName: "exclamationmark.shield")
    optionsButton.showsMenuAsPrimaryAction = true
    optionsButton.changesSelectionAsPrimaryAction = false
    optionsButton.accessibilityLabel = "Agent options"
    rebuildOptionsMenu()
    configureIconButton(micButton, systemName: "mic")
    configureIconButton(sendButton, systemName: "arrow.up")
    sendButton.backgroundColor = UIColor.white.withAlphaComponent(0.20)
    sendButton.layer.cornerRadius = 21
    sendButton.layer.cornerCurve = .continuous
    sendButton.addTarget(self, action: #selector(handleSend), for: .touchUpInside)
    [plusButton, optionsButton, micButton, sendButton].forEach(addSubview)

    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
      overlayView.topAnchor.constraint(equalTo: topAnchor),
      overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
      overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
      overlayView.bottomAnchor.constraint(equalTo: bottomAnchor),

      plusButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
      plusButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      plusButton.widthAnchor.constraint(equalToConstant: 42),
      plusButton.heightAnchor.constraint(equalToConstant: 42),

      optionsButton.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 2),
      optionsButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      optionsButton.widthAnchor.constraint(equalToConstant: 38),
      optionsButton.heightAnchor.constraint(equalToConstant: 42),

      sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      sendButton.widthAnchor.constraint(equalToConstant: 42),
      sendButton.heightAnchor.constraint(equalToConstant: 42),

      micButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
      micButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      micButton.widthAnchor.constraint(equalToConstant: 38),
      micButton.heightAnchor.constraint(equalToConstant: 42),

      textView.leadingAnchor.constraint(equalTo: optionsButton.trailingAnchor, constant: 8),
      textView.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -8),
      textView.topAnchor.constraint(equalTo: topAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

      placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
      placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
      placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 10),
    ])

    applyAppearance(.fallback)
  }

  private func configureIconButton(_ button: UIButton, systemName: String) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setImage(UIImage(systemName: systemName), for: .normal)
    button.imageView?.contentMode = .scaleAspectFit
    button.tintColor = .white
  }

  @objc private func handleSend() {
    let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, onSend != nil else { return }
    let options = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
    textView.text = ""
    textViewDidChange(textView)
    onSend?(text, options)
  }

  func textViewDidBeginEditing(_ textView: UITextView) {
  }

  func textViewDidEndEditing(_ textView: UITextView) {
  }

  func textViewDidChange(_ textView: UITextView) {
    placeholderLabel.isHidden = !textView.text.isEmpty
    updateSendState()
  }

  private func updateSendState() {
    let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let enabled = hasText && onSend != nil
    sendButton.isEnabled = enabled
    sendButton.tintColor = enabled ? appearance.background : appearance.textSecondary
    sendButton.backgroundColor = enabled ? appearance.text : appearance.textSecondary.withAlphaComponent(0.24)
  }

  private func rebuildOptionsMenu() {
    let selectedOptions = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
    let intelligenceActions = AgentBridgeIntelligenceLevel.allCases.map { level in
      UIAction(
        title: level.title,
        state: selectedOptions.intelligence == level ? .on : .off
      ) { [weak self] _ in
        AgentBridgeSelectionStore.setIntelligence(level)
        self?.rebuildOptionsMenu()
      }
    }

    let modelActions = modelChoices(for: provider).map { choice in
      UIAction(
        title: choice.title,
        subtitle: choice.subtitle,
        state: choice.value == selectedOptions.model ? .on : .off
      ) { [weak self] _ in
        AgentBridgeSelectionStore.setModel(provider: self?.provider ?? "codex", model: choice.value)
        self?.rebuildOptionsMenu()
      }
    }

    let speedActions = AgentBridgeSpeedMode.allCases.map { speed in
      UIAction(
        title: speed.title,
        state: selectedOptions.speed == speed ? .on : .off
      ) { [weak self] _ in
        AgentBridgeSelectionStore.setSpeed(speed)
        self?.rebuildOptionsMenu()
      }
    }

    optionsButton.menu = UIMenu(
      title: "Intelligence",
      children: intelligenceActions + [
        UIMenu(title: "Model", subtitle: selectedOptions.model ?? "Provider default", children: modelActions),
        UIMenu(title: "Speed", subtitle: selectedOptions.speed.title, children: speedActions),
      ]
    )
  }

  private func modelChoices(for provider: String) -> [(title: String, subtitle: String?, value: String?)] {
    switch provider.lowercased() {
    case "claude":
      return [
        ("Provider default", nil, nil),
        ("Sonnet", "Claude Code alias", "sonnet"),
        ("Opus", "Claude Code alias", "opus"),
      ]
    default:
      return [
        ("Provider default", nil, nil),
        ("GPT-5.5", nil, "gpt-5.5"),
        ("GPT-5.3 Codex", nil, "gpt-5.3-codex"),
      ]
    }
  }
}
