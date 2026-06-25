import SwiftUI
import UIKit

// Profile surfaces for a Claude/Codex bridge agent:
//   * AgentBridgeConnectionSheet — which computer is connected, Disconnect, and
//     Reconnect / Add connection (scan the QR the daemon prints).
//   * AgentBridgeHistoryView — the agent's OWN past Claude/Codex conversations
//     (topics → transcript), read from the connected computer via the bridge.
//     Rendered as a topic list + plain transcript, never chat bubbles.
//
// Both are presented from `ChatProfileMainView` for Claude/Codex profiles.

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

  static func presentHistory(provider: String, chatId: String, from presenter: UIViewController) {
    let root = AgentBridgeHistoryView(provider: provider, chatId: chatId)
    let host = UIHostingController(rootView: root)
    host.modalPresentationStyle = .pageSheet
    if let sheet = host.sheetPresentationController {
      sheet.detents = [.large()]
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

struct AgentBridgeHistorySession: Identifiable {
  let id: String
  let topic: String
  let projectName: String
  let updatedAt: String
  let messageCount: Int
}

struct AgentBridgeTranscriptMessage: Identifiable {
  let id = UUID()
  let role: String
  let text: String
}

struct AgentBridgeHistoryView: View {
  let provider: String
  let chatId: String

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  @State private var sessions: [AgentBridgeHistorySession] = []
  @State private var loading = true
  @State private var errorMessage: String?
  @State private var pendingRequestId: String?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }
  private var displayName: String { AgentBridgeProfile.displayName(for: provider) }

  var body: some View {
    NavigationStack {
      Group {
        if loading && sessions.isEmpty {
          VStack(spacing: 12) {
            ProgressView()
            Text("Reading \(displayName) history from your computer…")
              .font(.system(size: 13))
              .foregroundStyle(palette.secondaryText)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sessions.isEmpty {
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
          List(sessions) { session in
            NavigationLink {
              AgentBridgeTranscriptView(
                provider: provider,
                chatId: chatId,
                sessionId: session.id,
                topic: session.topic
              )
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(session.topic)
                  .font(.system(size: 15, weight: .semibold))
                  .foregroundStyle(palette.text)
                  .lineLimit(2)
                HStack(spacing: 6) {
                  if !session.projectName.isEmpty {
                    Text(session.projectName)
                      .lineLimit(1)
                    Text("·")
                  }
                  Text("\(session.messageCount) messages")
                  if let when = Self.relativeDate(session.updatedAt) {
                    Text("·")
                    Text(when)
                  }
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
              }
              .padding(.vertical, 2)
            }
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("\(displayName) history")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: ChatEngine.didChangeNotification)) { note in
      handle(note)
    }
    .onAppear { requestList() }
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
      guard let id = (item["id"] as? String), !id.isEmpty else { return nil }
      return AgentBridgeHistorySession(
        id: id,
        topic: (item["topic"] as? String) ?? "Untitled",
        projectName: (item["projectName"] as? String) ?? "",
        updatedAt: (item["updatedAt"] as? String) ?? "",
        messageCount: (item["messageCount"] as? NSNumber)?.intValue ?? (item["messageCount"] as? Int) ?? 0
      )
    }
    if sessions.isEmpty && (payload["ok"] as? Bool) == false {
      errorMessage = (payload["error"] as? String) ?? "Couldn't read history from your computer."
    }
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
