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
    return VibeAgentKitChatMessage(
      id: row.messageId ?? row.key,
      role: isUser ? .user : .assistant,
      text: body,
      timestamp: row.timestamp,
      timestampMs: 0,
      isStreaming: row.isAgentMessage && row.isStreamingText,
      isError: row.status == "failed",
      progress: [],
      progressItems: items
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
      if m.text.isEmpty && m.progressItems.isEmpty { return nil }
      return m
    }
  }
}

// MARK: - Full-page agent conversation surface

final class VibeAgentConversationViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

  private let tableView = UITableView(frame: .zero, style: .plain)
  private let progressSheet = VibeAgentKitAgentProgressSheetView()
  private var messages: [VibeAgentKitChatMessage]
  private var appearance: VibeAgentKitChatAppearance
  private let regeneratePrompt: String

  /// Tapping a message's progress row opens the full tool sheet for that message.
  /// Stashed so we know which message's items to present.
  private var progressItemsByMessageId: [String: [VibeAgentKitProgressItem]] = [:]

  init(title: String, messages: [VibeAgentKitChatMessage], regeneratePrompt: String = "") {
    self.messages = messages
    self.regeneratePrompt = regeneratePrompt
    self.appearance = .fallback
    super.init(nibName: nil, bundle: nil)
    self.title = title
  }

  required init?(coder: NSCoder) { return nil }

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

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.backgroundColor = appearance.background
    tableView.separatorStyle = .none
    tableView.dataSource = self
    tableView.delegate = self
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 96.0
    tableView.keyboardDismissMode = .interactive
    tableView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 24, right: 0)
    tableView.register(VibeAgentKitMessageCell.self, forCellReuseIdentifier: VibeAgentKitMessageCell.reuseIdentifier)
    view.addSubview(tableView)

    progressSheet.translatesAutoresizingMaskIntoConstraints = false
    progressSheet.applyAppearance(appearance)
    progressSheet.isHidden = true
    view.addSubview(progressSheet)

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      progressSheet.topAnchor.constraint(equalTo: view.topAnchor),
      progressSheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      progressSheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      progressSheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    indexProgress()
    DispatchQueue.main.async { [weak self] in self?.scrollToBottom(animated: false) }
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    if traitCollection.userInterfaceStyle != previous?.userInterfaceStyle {
      appearance = VibeAgentKitMap.appearance(for: traitCollection)
      view.backgroundColor = appearance.background
      tableView.backgroundColor = appearance.background
      progressSheet.applyAppearance(appearance)
      tableView.reloadData()
    }
  }

  // MARK: Live updates

  /// Replace the rendered messages (e.g. when the agent stream advances). Cheap
  /// reload is fine here — the surface is single-task and short.
  func setMessages(_ newMessages: [VibeAgentKitChatMessage]) {
    let wasNearBottom = isNearBottom()
    messages = newMessages
    indexProgress()
    tableView.reloadData()
    if wasNearBottom { scrollToBottom(animated: true) }
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
    cell.configure(message: message, appearance: appearance, regeneratePrompt: regeneratePrompt)
    cell.onProgressTap = { [weak self] in self?.presentProgress(for: message.id) }
    return cell
  }

  // MARK: Progress sheet

  private func presentProgress(for messageId: String) {
    guard let items = progressItemsByMessageId[messageId], !items.isEmpty else { return }
    progressSheet.isHidden = false
    progressSheet.onDismiss = { [weak self] in self?.progressSheet.isHidden = true }
    progressSheet.present(items: items, animated: true)
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
