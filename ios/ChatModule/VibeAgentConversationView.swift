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
  static func progressItem(from node: ChatListRow.AgentProgressNode) -> VibeAgentKitProgressItem {
    VibeAgentKitProgressItem(
      label: chatAgentNodeCompactLabel(node),
      badges: [],
      eventType: "progress",
      recipient: nil,
      platform: nil,
      format: nil,
      messageContent: nil,
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

  /// A chat row -> a render message. User rows render as right-side bubbles; agent
  /// rows render as the assistant body (streaming text + progress).
  static func chatMessage(from row: ChatListRow) -> VibeAgentKitChatMessage {
    let isUser = row.isMe && !row.isAgentMessage
    let body = row.isAgentMessage ? (row.plainContent ?? row.text) : row.text
    // Only depth-0 enriched nodes belong in the flat tool feed (the built-in Vibe
    // AI nested tree keeps its own minimalist behavior in the chat list).
    let items = row.isAgentMessage
      ? row.agentProgressNodes.filter { $0.depth == 0 }.map(progressItem(from:))
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

  /// Build the seed message list for a task. `rows` should already be the slice of
  /// chat rows that belong to this task (the prompt + the agent reply, and any
  /// prior turns when resumed).
  static func messages(from rows: [ChatListRow]) -> [VibeAgentKitChatMessage] {
    rows.compactMap { row in
      guard case .message = row.kind else { return nil }
      // Skip empty system/placeholder rows.
      let m = chatMessage(from: row)
      if m.text.isEmpty && m.progressItems.isEmpty && m.runtime == nil { return nil }
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
  private let onSend: ((String) -> Void)?
  private var tableBottomConstraint: NSLayoutConstraint?
  private var composerBottomConstraint: NSLayoutConstraint?
  private var composerHeightConstraint: NSLayoutConstraint?
  private var changeObserver: NSObjectProtocol?
  private var keyboardObservers: [NSObjectProtocol] = []

  /// Tapping a message's progress row opens the full tool sheet for that message.
  /// Stashed so we know which message's items to present.
  private var progressItemsByMessageId: [String: [VibeAgentKitProgressItem]] = [:]

  /// Chat + provider context (history surface) so a runtime card can route a
  /// full-file-open request to the user's bridge. Nil in the live agent view.
  var agentBridgeChatId: String?
  var agentBridgeProvider: String?

  init(
    title: String,
    subtitle: String = "",
    messages: [VibeAgentKitChatMessage],
    regeneratePrompt: String = "",
    inputPlaceholder: String? = nil,
    messagesProvider: (() -> [VibeAgentKitChatMessage])? = nil,
    onSend: ((String) -> Void)? = nil
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
    composerView.onSend = { [weak self] text in
      self?.onSend?(text)
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
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
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
    cell.onProgressTap = { [weak self] in self?.presentProgress(for: message.id) }
    cell.onRuntimeTap = { [weak self] runtime in self?.presentRuntime(runtime) }
    cell.configure(
      message: message,
      appearance: appearance,
      regeneratePrompt: regeneratePrompt,
      showsActions: false
    )
    return cell
  }

  // MARK: Progress sheet

  private func presentProgress(for messageId: String) {
    guard let items = progressItemsByMessageId[messageId], !items.isEmpty else { return }
    progressSheet.isHidden = false
    progressSheet.onDismiss = { [weak self] in self?.progressSheet.isHidden = true }
    progressSheet.present(items: items, animated: true)
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
    guard messages.count > 0 else { return }
    let last = IndexPath(row: messages.count - 1, section: 0)
    tableView.scrollToRow(at: last, at: .bottom, animated: animated)
  }
}

private final class VibeAgentRuntimeComposerView: UIView, UITextViewDelegate {
  var onSend: ((String) -> Void)? {
    didSet { updateSendState() }
  }
  var onHeightChanged: ((CGFloat) -> Void)?
  var placeholder: String = "Ask Codex" {
    didSet { placeholderLabel.text = placeholder }
  }

  private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
  private let overlayView = UIView()
  private let textView = UITextView()
  private let placeholderLabel = UILabel()
  private let topControlsView = UIView()
  private let controlsLabel = UILabel()
  private let plusButton = UIButton(type: .system)
  private let micButton = UIButton(type: .system)
  private let sendButton = UIButton(type: .system)
  private var appearance: VibeAgentKitChatAppearance = .fallback
  private var expanded = false
  private var textTopCompactConstraint: NSLayoutConstraint?
  private var textTopExpandedConstraint: NSLayoutConstraint?

  var preferredHeight: CGFloat {
    expanded ? 126 : 64
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
    controlsLabel.textColor = appearance.textSecondary
    [plusButton, micButton].forEach { button in
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

    topControlsView.translatesAutoresizingMaskIntoConstraints = false
    topControlsView.alpha = 0
    addSubview(topControlsView)

    controlsLabel.text = "5.5  Extra High"
    controlsLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
    controlsLabel.textAlignment = .center
    controlsLabel.translatesAutoresizingMaskIntoConstraints = false
    topControlsView.addSubview(controlsLabel)

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
    configureIconButton(micButton, systemName: "mic")
    configureIconButton(sendButton, systemName: "arrow.up")
    sendButton.backgroundColor = UIColor.white.withAlphaComponent(0.20)
    sendButton.layer.cornerRadius = 21
    sendButton.layer.cornerCurve = .continuous
    sendButton.addTarget(self, action: #selector(handleSend), for: .touchUpInside)
    [plusButton, micButton, sendButton].forEach(addSubview)

    let textTopCompactConstraint = textView.topAnchor.constraint(equalTo: topAnchor)
    let textTopExpandedConstraint = textView.topAnchor.constraint(equalTo: topControlsView.bottomAnchor)
    textTopExpandedConstraint.isActive = false
    self.textTopCompactConstraint = textTopCompactConstraint
    self.textTopExpandedConstraint = textTopExpandedConstraint

    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
      overlayView.topAnchor.constraint(equalTo: topAnchor),
      overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
      overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
      overlayView.bottomAnchor.constraint(equalTo: bottomAnchor),

      topControlsView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      topControlsView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 54),
      topControlsView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -54),
      topControlsView.heightAnchor.constraint(equalToConstant: 28),
      controlsLabel.centerXAnchor.constraint(equalTo: topControlsView.centerXAnchor),
      controlsLabel.centerYAnchor.constraint(equalTo: topControlsView.centerYAnchor),

      plusButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
      plusButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      plusButton.widthAnchor.constraint(equalToConstant: 42),
      plusButton.heightAnchor.constraint(equalToConstant: 42),

      sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      sendButton.widthAnchor.constraint(equalToConstant: 42),
      sendButton.heightAnchor.constraint(equalToConstant: 42),

      micButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
      micButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      micButton.widthAnchor.constraint(equalToConstant: 38),
      micButton.heightAnchor.constraint(equalToConstant: 42),

      textView.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 10),
      textView.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -8),
      textTopCompactConstraint,
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
    textView.text = ""
    textViewDidChange(textView)
    onSend?(text)
  }

  func textViewDidBeginEditing(_ textView: UITextView) {
    setExpanded(true, animated: true)
  }

  func textViewDidEndEditing(_ textView: UITextView) {
    if textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      setExpanded(false, animated: true)
    }
  }

  func textViewDidChange(_ textView: UITextView) {
    placeholderLabel.isHidden = !textView.text.isEmpty
    updateSendState()
  }

  private func setExpanded(_ value: Bool, animated: Bool) {
    guard expanded != value else { return }
    expanded = value
    textTopCompactConstraint?.isActive = !value
    textTopExpandedConstraint?.isActive = value
    onHeightChanged?(preferredHeight)
    let changes = {
      self.topControlsView.alpha = value ? 1 : 0
      self.layoutIfNeeded()
    }
    if animated {
      UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: changes)
    } else {
      changes()
    }
  }

  private func updateSendState() {
    let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let enabled = hasText && onSend != nil
    sendButton.isEnabled = enabled
    sendButton.tintColor = enabled ? appearance.background : appearance.textSecondary
    sendButton.backgroundColor = enabled ? appearance.text : appearance.textSecondary.withAlphaComponent(0.24)
  }
}
