import SwiftUI
import UIKit

// Profile surfaces for a Claude/Codex bridge agent:
//   * AgentBridgeConnectionSheet — which computer is connected, Disconnect, and
//     Reconnect / Add connection (scan the QR the daemon prints).
//   * AgentBridgeHistoryInlineView — the agent's OWN past Claude/Codex
//     conversations (topic list), read from the connected computer via the
//     bridge. Pushed into `ChatProfileMainView`'s NavigationStack so it
//     morph-expands from the "Chat History" row. Tapping a topic pushes the
//     dedicated agent runtime surface with the topic header and composer.
//
// The connection sheet is presented; the history is pushed (morph) from
// `ChatProfileMainView` for Claude/Codex profiles.
//
// `AgentBridgeTranscriptView` below is retained as a standalone fallback
// renderer but is no longer wired into the profile navigation.

enum AgentBridgeProfile {
  static func displayName(for provider: String) -> String {
    switch provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "claude": return "Claude"
    case "codex": return "Codex"
    default: return provider.capitalized
    }
  }

    @MainActor static func presentConnection(provider: String, from presenter: UIViewController) {
    let model = AgentConnectModel(provider: provider, displayName: displayName(for: provider))
    let host = UIHostingController(rootView: AgentBridgeConnectionSheet(model: model))
    host.modalPresentationStyle = .pageSheet
    if let sheet = host.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    presenter.present(host, animated: true)
  }

}

// MARK: - Connection sheet (connect / disconnect / reconnect)

struct AgentBridgeConnectionSheet: View {
  @ObservedObject var model: AgentConnectModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  @State private var isWorking = false
  @State private var errorMessage: String?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    NavigationView {
      List {
        Section {
          connectionRow
        } header: {
          Text("Computer")
        } footer: {
          Text("\(model.displayName) runs on your own computer with your own subscription. Pairing is revocable and only you can connect a computer.")
        }

        Section {
          Button {
            model.beginScan()
          } label: {
            Label(
              model.status.paired || model.status.connected ? "Reconnect — scan QR" : "Add connection",
              systemImage: "qrcode.viewfinder"
            )
          }
          .disabled(isWorking)

          if model.status.paired || model.status.connected {
            Button(role: .destructive) {
              disconnect()
            } label: {
              Label("Disconnect computer", systemImage: "xmark.circle")
            }
            .disabled(isWorking)
          }
        } footer: {
          if model.status.paired || model.status.connected {
            Text("Disconnect revokes this computer's pairing token and stops the bridge. To reconnect you scan the QR the daemon prints again.")
          } else {
            Text("On your computer run the bridge — it prints a QR. Scan it here to connect.")
          }
        }

        if let errorMessage {
          Section {
            Text(errorMessage)
              .font(.system(size: 13))
              .foregroundStyle(.red)
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("\(model.displayName) computer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
    .onAppear { model.startPolling() }
    .onDisappear { model.stopPolling() }
    .fullScreenCover(isPresented: $model.isScanning) {
      AgentQRScannerView(
        instruction: "Scan the QR shown on your computer",
        onResult: { model.handleScanned($0) },
        onCancel: { model.cancelScan() }
      )
      .ignoresSafeArea()
    }
  }

  @ViewBuilder
  private var connectionRow: some View {
    if model.status.connected, let device = model.status.devices.first {
      statusRow(
        icon: "laptopcomputer",
        title: device.label,
        subtitle: "Connected",
        subtitleColor: .green,
        showsDot: true
      )
    } else if model.status.paired {
      statusRow(
        icon: "laptopcomputer.slash",
        title: model.status.devices.first?.label ?? "Your computer",
        subtitle: "Paired — bridge offline",
        subtitleColor: palette.secondaryText
      )
    } else {
      statusRow(
        icon: "laptopcomputer.slash",
        title: "No computer connected",
        subtitle: "Pair one to start",
        subtitleColor: palette.secondaryText
      )
    }
  }

  private func statusRow(
    icon: String,
    title: String,
    subtitle: String,
    subtitleColor: Color,
    showsDot: Bool = false
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(palette.accent)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(palette.text)
          .lineLimit(1)
        Text(subtitle)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(subtitleColor)
      }
      Spacer(minLength: 8)
      if showsDot {
        Circle().fill(Color.green).frame(width: 9, height: 9)
      }
    }
    .padding(.vertical, 2)
  }

  private func disconnect() {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return
    }
    isWorking = true
    errorMessage = nil
    Task {
      defer { isWorking = false }
      do {
        try await AgentPairingService.revoke(config: config)
        model.stopPolling()
        await MainActor.run { model.status = .disconnected }
        model.startPolling()
      } catch {
        await MainActor.run { errorMessage = error.localizedDescription }
      }
    }
  }
}

// MARK: - History (topics → transcript), read from the connected computer

struct AgentBridgeHistorySession: Identifiable, Hashable {
  let id: String
  let topic: String
  let projectName: String
  let projectPath: String
  let updatedAt: String
  let messageCount: Int
  let isRunning: Bool
  let taskId: String?
  let sessionId: String?

  var resolvedSessionId: String {
    if let sessionId, !sessionId.isEmpty { return sessionId }
    return id
  }

  var projectKey: String {
    let path = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !path.isEmpty { return path }
    let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "Computer" : name
  }

  var displayProjectName: String {
    let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty { return name }
    let path = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !path.isEmpty { return URL(fileURLWithPath: path).lastPathComponent }
    return "Computer"
  }
}

private struct AgentBridgeHistoryProjectGroup: Identifiable {
  let id: String
  let name: String
  let sessions: [AgentBridgeHistorySession]
}

struct AgentBridgeTranscriptMessage: Identifiable {
  let id = UUID()
  let role: String
  let text: String
}

// Inline history list, designed to be PUSHED into the profile's own
// NavigationStack rather than presented as a sheet. Selecting a topic pushes the
// dedicated agent runtime surface instead of injecting rows into the default chat.
struct AgentBridgeHistoryInlineView: View {
  let provider: String
  let chatId: String
  var runningTasks: [AgentBridgeRunningTask] = []
  let onOpenSession: (AgentBridgeHistorySession) -> Void

  @Environment(\.colorScheme) private var colorScheme

  @State private var sessions: [AgentBridgeHistorySession] = []
  @State private var loading = true
  @State private var errorMessage: String?
  @State private var pendingRequestId: String?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }
  private var displayName: String { AgentBridgeProfile.displayName(for: provider) }
  private var visibleSessions: [AgentBridgeHistorySession] { mergedSessions() }
  private var projectGroups: [AgentBridgeHistoryProjectGroup] {
    var groups: [AgentBridgeHistoryProjectGroup] = []
    var indexByKey: [String: Int] = [:]
    for session in visibleSessions {
      let key = session.projectKey
      if let index = indexByKey[key] {
        var existing = groups[index]
        existing = AgentBridgeHistoryProjectGroup(
          id: existing.id,
          name: existing.name,
          sessions: existing.sessions + [session]
        )
        groups[index] = existing
      } else {
        indexByKey[key] = groups.count
        groups.append(AgentBridgeHistoryProjectGroup(
          id: key,
          name: session.displayProjectName,
          sessions: [session]
        ))
      }
    }
    return groups
  }

  var body: some View {
    Group {
      if loading && visibleSessions.isEmpty {
        VStack(spacing: 12) {
          ProgressView()
          Text("Reading \(displayName) history from your computer…")
            .font(.system(size: 13))
            .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if visibleSessions.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: errorMessage == nil ? "clock.badge.questionmark" : "laptopcomputer.slash")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(palette.secondaryText)
          Text(errorMessage ?? "No \(displayName) conversations found on your computer.")
            .font(.system(size: 14))
            .foregroundStyle(palette.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(projectGroups) { group in
            Section {
              ForEach(group.sessions) { session in
                sessionRow(session)
              }
            } header: {
              projectHeader(group)
            }
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
    }
    .navigationTitle("\(displayName) history")
    .navigationBarTitleDisplayMode(.inline)
    .onReceive(NotificationCenter.default.publisher(for: ChatEngine.didChangeNotification)) { note in
      handle(note)
    }
    .onAppear { requestList() }
  }

  private func projectHeader(_ group: AgentBridgeHistoryProjectGroup) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "folder")
        .font(.system(size: 16, weight: .semibold))
      Text(group.name)
        .font(.system(size: 20, weight: .bold))
      Spacer(minLength: 0)
    }
    .textCase(nil)
    .foregroundStyle(palette.text)
    .padding(.top, 14)
    .padding(.bottom, 6)
  }

  private func sessionRow(_ session: AgentBridgeHistorySession) -> some View {
    Button {
      onOpenSession(session)
    } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 7) {
            if session.isRunning {
              Circle().fill(Color.green).frame(width: 8, height: 8)
            }
            Text(session.topic)
              .font(.system(size: 18, weight: .regular))
              .foregroundStyle(palette.text)
              .lineLimit(2)
          }
          HStack(spacing: 6) {
            if session.isRunning {
              Text("Running")
            } else {
              Text("\(session.messageCount) messages")
            }
            if let when = Self.relativeDate(session.updatedAt) {
              Text("·")
              Text(when)
            }
          }
          .font(.system(size: 12))
          .foregroundStyle(session.isRunning ? Color.green.opacity(0.9) : palette.secondaryText)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(palette.secondaryText.opacity(0.7))
      }
      .padding(.vertical, 9)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func requestList() {
    loading = true
    errorMessage = nil
    let result = ChatEngine.shared.requestAgentBridgeHistory([
      "chatId": chatId,
      "provider": provider,
      "mode": "list",
    ])
    if (result["accepted"] as? Bool) == true {
      pendingRequestId = result["requestId"] as? String
    } else {
      loading = false
      errorMessage = "Your computer isn't connected right now. Connect it, then try again."
    }
  }

  private func handle(_ note: Notification) {
    guard
      let info = note.userInfo,
      (info["reason"] as? String) == "agentBridgeHistory",
      let payload = ChatEngine.shared.latestAgentBridgeHistory(chatId: chatId)
    else { return }

    // Only react to the list reply we asked for (transcripts use a different id).
    if let pending = pendingRequestId, let rid = info["requestId"] as? String, rid != pending {
      return
    }
    guard (payload["mode"] as? String ?? "list") == "list" else { return }

    loading = false
    let raw = payload["sessions"] as? [[String: Any]] ?? []
    sessions = raw.compactMap { item in
      Self.parseSession(item)
    }
    if sessions.isEmpty && (payload["ok"] as? Bool) == false {
      errorMessage = (payload["error"] as? String) ?? "Couldn't read history from your computer."
    }
  }

  private func mergedSessions() -> [AgentBridgeHistorySession] {
    let running = runningTasks.compactMap { task -> AgentBridgeHistorySession? in
      let normalizedProvider = task.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if !normalizedProvider.isEmpty && normalizedProvider != provider.lowercased() { return nil }
      if !task.chatId.isEmpty && !chatId.isEmpty && task.chatId != chatId { return nil }
      let id = task.sessionId?.isEmpty == false ? task.sessionId! : "running:\(task.taskId)"
      return AgentBridgeHistorySession(
        id: id,
        topic: task.topic,
        projectName: task.projectName ?? task.repoName ?? "",
        projectPath: task.project ?? task.cwd ?? "",
        updatedAt: task.startedAt ?? "",
        messageCount: 0,
        isRunning: true,
        taskId: task.taskId,
        sessionId: task.sessionId
      )
    }
    var seen = Set(running.map(\.id))
    return running + sessions.filter { session in
      if seen.contains(session.id) { return false }
      seen.insert(session.id)
      return true
    }
  }

  static func parseSession(_ item: [String: Any]) -> AgentBridgeHistorySession? {
    guard let id = (item["id"] as? String), !id.isEmpty else { return nil }
    let projectPath =
      (item["project"] as? String)
      ?? (item["projectPath"] as? String)
      ?? (item["cwd"] as? String)
      ?? ""
    return AgentBridgeHistorySession(
      id: id,
      topic: (item["topic"] as? String) ?? "Untitled",
      projectName: (item["projectName"] as? String) ?? "",
      projectPath: projectPath,
      updatedAt: (item["updatedAt"] as? String) ?? "",
      messageCount: (item["messageCount"] as? NSNumber)?.intValue ?? (item["messageCount"] as? Int) ?? 0,
      isRunning: false,
      taskId: nil,
      sessionId: id
    )
  }

  static func relativeDate(_ iso: String) -> String? {
    let trimmed = iso.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: trimmed)
      ?? ISO8601DateFormatter().date(from: trimmed)
    guard let date else { return nil }
    let rel = RelativeDateTimeFormatter()
    rel.unitsStyle = .abbreviated
    return rel.localizedString(for: date, relativeTo: Date())
  }
}

struct AgentBridgeRuntimeView: UIViewControllerRepresentable {
  let provider: String
  let chatId: String
  let session: AgentBridgeHistorySession
  let subtitle: String

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIViewController(context: Context) -> VibeAgentConversationViewController {
    // Capture value-type context so the live closures don't retain SwiftUI state.
    let chatId = chatId
    let provider = provider
    let sessionId = session.resolvedSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
    let coordinator = context.coordinator

    let controller = VibeAgentConversationViewController(
      title: session.topic,
      subtitle: subtitle,
      messages: context.coordinator.seedMessages(),
      inputPlaceholder: "Ask \(AgentBridgeProfile.displayName(for: provider))",
      // Render this session's rows. Every session ingests into the same DM chatId
      // (keyed `bridge-<sessionId>-…`), so reading the chat unfiltered would show the
      // default-DM history identically for every session. We isolate to the ingested
      // transcript for this session id, PLUS — once the user sends a follow-up from
      // this view — that follow-up and its resumed reply (the live `agent-stream`
      // bubble and the final message, linked back by source id). Without that, a
      // resume landed in the shared DM with a non-`bridge-` id and was filtered out,
      // so the view looked empty/stuck. We still never pull in another session's
      // ingested history (also `bridge-`prefixed) or the DM's unrelated rows. If the
      // transcript hasn't arrived yet we fall back to live streaming rows so a
      // running task isn't blank. The controller's live observer re-reads this on
      // every engine change.
      messagesProvider: { [weak coordinator] in
        let prefix = "bridge-\(sessionId)-"
        let all = ChatEngine.shared
          .getChatRows(["chatId": chatId])
          .compactMap { ChatListRow(raw: $0) }
        // Follow-ups that resume THIS session: identified durably by the resume
        // session id their send stamped into metadata (so a follow-up sent from
        // ANOTHER device folds in too), plus any this device sent locally. Their
        // replies (live stream + final message) link back by source id.
        var followUps = coordinator?.followUpMessageIds ?? []
        for row in all where row.agentBridgeResumeSessionId == sessionId {
          if let mid = row.messageId { followUps.insert(mid) }
        }
        let keep = all.filter { row in
          let mid = row.messageId ?? ""
          if mid.hasPrefix(prefix) { return true }
          guard !followUps.isEmpty else { return false }
          if mid.hasPrefix("bridge-") { return false }
          if followUps.contains(mid) { return true }
          if let src = row.agentActionSourceId, followUps.contains(src) { return true }
          if row.isStreamingText { return true }
          return false
        }
        if !keep.isEmpty {
          return VibeAgentKitMap.messages(from: keep)
        }
        let liveRows = all.filter { $0.isStreamingText }
        return VibeAgentKitMap.messages(from: liveRows)
      },
      // Send continues THIS session on the user's computer and streams back in place.
      onSend: { [weak coordinator] text, options in
        coordinator?.sendFollowUp(text, options: options)
      }
    )
    controller.agentBridgeChatId = chatId
    controller.agentBridgeProvider = provider
    context.coordinator.controller = controller
    context.coordinator.start()
    return controller
  }

  func updateUIViewController(_ controller: VibeAgentConversationViewController, context: Context) {
    context.coordinator.parent = self
    context.coordinator.controller = controller
  }

  /// Dispatch a message to the agent on the user's computer over the live chat
  /// channel. The server detects the bridge-agent DM and routes to the daemon; the
  /// reply streams back as `agent-stream` / `message` frames that ChatEngine folds
  /// into this chat's rows (rendered via `messagesProvider`).
  static func sendToAgent(
    chatId: String,
    provider: String,
    resumeSessionId: String,
    text: String,
    messageId: String = UUID().uuidString.lowercased(),
    options: AgentBridgeRunOptions? = nil
  ) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var metadata: [String: Any] = ["agentBridgeProvider": provider]
    if let repo = AgentBridgeSelectionStore.selectedRepository() {
      metadata["agentBridgeRepoId"] = repo.id
      metadata["agentBridgeRepoName"] = repo.name
      metadata["agentBridgeRepoPath"] = repo.path
      metadata["agentBridgeCwd"] = repo.cwd
    }
    metadata["agentBridgeWorkMode"] = AgentBridgeSelectionStore.selectedWorkMode().rawValue
    metadata.merge(
      (options ?? AgentBridgeSelectionStore.selectedRunOptions(provider: provider)).payload(provider: provider)
    ) { _, new in new }
    // Explicit resume so the message continues the session you opened rather than
    // starting a fresh task (per the resume contract).
    if !resumeSessionId.isEmpty, !resumeSessionId.hasPrefix("running:") {
      metadata["agentBridgeResumeSessionId"] = resumeSessionId
    }
    _ = ChatEngine.shared.sendMessage([
      "chatId": chatId,
      "type": "text",
      "text": trimmed,
      "messageId": messageId,
      "metadata": metadata,
    ])
  }

  final class Coordinator {
    var parent: AgentBridgeRuntimeView
    weak var controller: VibeAgentConversationViewController?
    private var didOpenChannel = false

    /// Message ids of follow-ups the user sent from THIS view. The live
    /// `messagesProvider` uses these to fold the resumed turn (the follow-up bubble
    /// plus its streaming + final reply, joined by source id) into the rendered
    /// transcript — otherwise a resume lands in the shared DM with a non-`bridge-`
    /// id and gets filtered out, leaving the view looking empty.
    var followUpMessageIds: Set<String> = []

    init(parent: AgentBridgeRuntimeView) {
      self.parent = parent
    }

    /// Send a follow-up that resumes this session and surface it inline. We mint the
    /// id up front so we can register it before dispatch; the engine's optimistic
    /// insert + the streamed/final reply then render through `messagesProvider`.
    func sendFollowUp(_ text: String, options: AgentBridgeRunOptions) {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      let messageId = UUID().uuidString.lowercased()
      followUpMessageIds.insert(messageId)
      AgentBridgeRuntimeView.sendToAgent(
        chatId: parent.chatId,
        provider: parent.provider,
        resumeSessionId: parent.session.resolvedSessionId
          .trimmingCharacters(in: .whitespacesAndNewlines),
        text: trimmed,
        messageId: messageId,
        options: options
      )
    }

    deinit {
      if didOpenChannel {
        _ = ChatEngine.shared.closeChatChannel(["chatId": parent.chatId])
      }
    }

    func seedMessages() -> [VibeAgentKitChatMessage] {
      if parent.session.isRunning {
        return [
          VibeAgentKitChatMessage(
            id: parent.session.id,
            role: .assistant,
            text: "Running on \(parent.session.displayProjectName).",
            timestamp: "",
            timestampMs: 0,
            isStreaming: true
          )
        ]
      }
      // A finished conversation must NOT look live — no streaming shimmer. This is a
      // transient placeholder replaced as soon as the transcript loads.
      return [
        VibeAgentKitChatMessage(
          id: parent.session.id,
          role: .assistant,
          text: "Loading conversation…",
          timestamp: "",
          timestampMs: 0,
          isStreaming: false
        )
      ]
    }

    /// Join the chat channel (so live frames arrive) and ingest the selected local
    /// session into the chat as rows. From here the controller's own live observer
    /// re-reads `messagesProvider` on every engine change, so seeded history, live
    /// `agent-stream` deltas, and final `message`s all render through one path —
    /// no close-and-reload. The ingest carries each message's E2E `agentRuntimeEnc`
    /// so the file-change cards survive (decrypted by ChatListRow with the phone key).
    func start() {
      _ = ChatEngine.shared.openChatChannel(["chatId": parent.chatId])
      didOpenChannel = true

      let sessionId = parent.session.resolvedSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !sessionId.isEmpty, !sessionId.hasPrefix("running:") else { return }

      let result = ChatEngine.shared.loadAgentBridgeSessionIntoChat([
        "chatId": parent.chatId,
        "provider": parent.provider,
        "sessionId": sessionId,
      ])
      if (result["accepted"] as? Bool) != true {
        controller?.setMessages([
          VibeAgentKitChatMessage(
            id: "offline",
            role: .assistant,
            text: "Your computer is not connected right now.",
            timestamp: "",
            timestampMs: 0,
            isError: true
          )
        ])
      }
    }
  }
}

struct AgentBridgeTranscriptView: View {
  let provider: String
  let chatId: String
  let sessionId: String
  let topic: String

  @Environment(\.colorScheme) private var colorScheme

  @State private var messages: [AgentBridgeTranscriptMessage] = []
  @State private var loading = true
  @State private var errorMessage: String?
  @State private var pendingRequestId: String?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }
  private var displayName: String { AgentBridgeProfile.displayName(for: provider) }

  var body: some View {
    Group {
      if loading && messages.isEmpty {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if messages.isEmpty {
        Text(errorMessage ?? "This conversation is empty.")
          .font(.system(size: 14))
          .foregroundStyle(palette.secondaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            ForEach(messages) { message in
              VStack(alignment: .leading, spacing: 5) {
                Text(label(for: message.role))
                  .font(.system(size: 12, weight: .bold))
                  .foregroundStyle(color(for: message.role))
                  .textCase(.uppercase)
                Text(message.text)
                  .font(.system(size: 14))
                  .foregroundStyle(palette.text)
                  .textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(18)
        }
      }
    }
    .navigationTitle(topic)
    .navigationBarTitleDisplayMode(.inline)
    .onReceive(NotificationCenter.default.publisher(for: ChatEngine.didChangeNotification)) { note in
      handle(note)
    }
    .onAppear { requestDetail() }
  }

  private func label(for role: String) -> String {
    switch role.lowercased() {
    case "user": return "You"
    case "assistant": return displayName
    case "developer", "system": return "System"
    default: return role
    }
  }

  private func color(for role: String) -> Color {
    role.lowercased() == "user" ? palette.secondaryText : palette.accent
  }

  private func requestDetail() {
    loading = true
    errorMessage = nil
    let result = ChatEngine.shared.requestAgentBridgeHistory([
      "chatId": chatId,
      "provider": provider,
      "mode": "detail",
      "sessionId": sessionId,
    ])
    if (result["accepted"] as? Bool) == true {
      pendingRequestId = result["requestId"] as? String
    } else {
      loading = false
      errorMessage = "Your computer isn't connected right now."
    }
  }

  private func handle(_ note: Notification) {
    guard
      let info = note.userInfo,
      (info["reason"] as? String) == "agentBridgeHistory",
      let payload = ChatEngine.shared.latestAgentBridgeHistory(chatId: chatId)
    else { return }

    if let pending = pendingRequestId, let rid = info["requestId"] as? String, rid != pending {
      return
    }
    guard (payload["mode"] as? String) == "detail" else { return }
    guard let session = payload["session"] as? [String: Any] else { return }
    // Make sure this detail is for the session we opened.
    if let sid = session["id"] as? String, sid != sessionId { return }

    loading = false
    let raw = session["messages"] as? [[String: Any]] ?? []
    messages = raw.compactMap { item in
      let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !text.isEmpty else { return nil }
      return AgentBridgeTranscriptMessage(role: (item["role"] as? String) ?? "", text: text)
    }
    if messages.isEmpty {
      errorMessage = "This conversation has no readable messages."
    }
  }
}
