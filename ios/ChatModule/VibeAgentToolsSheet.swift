import SwiftUI
import PhotosUI

struct VibeAgentToolsSheet: View {
  var appearance: VibeAgentKitChatAppearance
  var provider: String
  var chatId: String?
  var allCommands: [VibeAgentSlashCommand]

  var onAttach: (() -> Void)?
  var onCamera: (() -> Void)?
  var onFile: (() -> Void)?
  var onSelectCommand: ((VibeAgentSlashCommand) -> Void)?
  var onDismiss: (() -> Void)?

  @State private var selectedModel: String?
  @State private var selectedAdvisor: String?
  @State private var selectedIntelligence: AgentBridgeIntelligenceLevel = .medium
  @State private var selectedWorkMode: AgentBridgeWorkMode = .askAuto
  /// Bumps when live model catalogs arrive so model/thinking lists re-render.
  @State private var catalogEpoch: Int = 0

  init(
    appearance: VibeAgentKitChatAppearance,
    provider: String,
    chatId: String? = nil,
    allCommands: [VibeAgentSlashCommand],
    onAttach: (() -> Void)? = nil,
    onCamera: (() -> Void)? = nil,
    onFile: (() -> Void)? = nil,
    onSelectCommand: ((VibeAgentSlashCommand) -> Void)? = nil,
    onDismiss: (() -> Void)? = nil
  ) {
    self.appearance = appearance
    self.provider = provider
    self.chatId = chatId
    self.allCommands = allCommands
    self.onAttach = onAttach
    self.onCamera = onCamera
    self.onFile = onFile
    self.onSelectCommand = onSelectCommand
    self.onDismiss = onDismiss

    let opts = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
    _selectedModel = State(initialValue: opts.model)
    _selectedAdvisor = State(initialValue: opts.advisor)
    _selectedIntelligence = State(initialValue: opts.intelligence)
    _selectedWorkMode = State(initialValue: AgentBridgeSelectionStore.selectedWorkMode())
  }

  // MARK: - Theme

  /// Row fill. In dark mode `appearance.surface` is a warm brown that reads too light
  /// over the sheet's glass — use a neutral, slightly-elevated fill instead so rows
  /// sit correctly in both themes.
  private var rowFill: Color {
    appearance.isDark
      ? Color.white.opacity(0.05)
      : Color(uiColor: appearance.surface)
  }

  private var text: Color { Color(uiColor: appearance.text) }
  private var textSecondary: Color { Color(uiColor: appearance.textSecondary) }
  private var textTertiary: Color { Color(uiColor: appearance.textTertiary) }

  // MARK: - Command buckets

  // `usage` is promoted to a dedicated push panel (progress bars), so drop it from the
  // flat INFO command list to avoid a duplicate that would just print text.
  private var info: [VibeAgentSlashCommand] { allCommands.filter { $0.kind == .bridge && $0.name != "usage" } }
  private var options: [VibeAgentSlashCommand] { allCommands.filter { $0.kind == .runOption } }
  private var slash: [VibeAgentSlashCommand] { allCommands.filter { $0.kind == .providerSlash } }
  private var cli: [VibeAgentSlashCommand] { allCommands.filter { $0.kind == .cli } }

  var body: some View {
    NavigationStack {
      List {
        // Attachment pills
        Section {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
              Button {
                onCamera?(); onDismiss?()
              } label: {
                VibeComposerAttachmentPill(title: "Camera", icon: "camera.fill", appearance: appearance)
              }
              .buttonStyle(.plain)

              Button {
                onAttach?(); onDismiss?()
              } label: {
                VibeComposerAttachmentPill(title: "Photo", icon: "photo.on.rectangle", appearance: appearance)
              }
              .buttonStyle(.plain)

              Button {
                onFile?(); onDismiss?()
              } label: {
                VibeComposerAttachmentPill(title: "File", icon: "doc.fill", appearance: appearance)
              }
              .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
          }
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        }

        // Run options — each pushes an inner selection page
        Section {
          NavigationLink {
            modelPage
          } label: {
            settingRowLabel(
              title: "Model",
              systemImage: "cpu",
              value: selectedModel == nil
                ? "\(AgentBridgeSelectionStore.defaultModelTitle(provider: provider)) default"
                : AgentBridgeSelectionStore.modelTitle(provider: provider, model: selectedModel)
            )
          }
          .listRowBackground(rowFill)

          if provider.lowercased() == "claude" {
            NavigationLink {
              advisorPage
            } label: {
              settingRowLabel(
                title: "Advisor",
                systemImage: "person.crop.circle.badge.checkmark",
                value: AgentBridgeSelectionStore.advisorTitle(provider: provider, advisor: selectedAdvisor)
              )
            }
            .listRowBackground(rowFill)
          }

          NavigationLink {
            thinkingPage
          } label: {
            settingRowLabel(title: "Thinking", systemImage: "brain", value: selectedIntelligence.title)
          }
          .listRowBackground(rowFill)

          NavigationLink {
            permissionPage
          } label: {
            settingRowLabel(title: "Permission", systemImage: selectedWorkMode.icon, value: selectedWorkMode.title)
          }
          .listRowBackground(rowFill)
        }

        // Usage — pushes a live panel (5h + weekly bars), fetched from the bridge with
        // no chat bubble. Only meaningful when we have a chat id to query against.
        if let chatId, !chatId.isEmpty {
          Section {
            NavigationLink {
              VibeAgentUsagePanel(chatId: chatId, provider: provider, appearance: appearance)
            } label: {
              settingRowLabel(title: "Usage", systemImage: "gauge.with.dots.needle.bottom.50percent", value: "")
            }
            .listRowBackground(rowFill)
          }
        }

        commandSection("INFO", info)
        commandSection("OPTIONS", options)
        commandSection("COMMANDS", slash)
        commandSection("TERMINAL", cli)
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(Color.clear)
      .navigationTitle("Add to Chat")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            onDismiss?()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 15, weight: .semibold))
          }
        }
      }
      .tint(text)
      .onAppear {
        AgentBridgeSelectionStore.refreshModelsIfPossible()
      }
      .onReceive(NotificationCenter.default.publisher(for: AgentBridgeSelectionStore.didChangeNotification)) { _ in
        catalogEpoch &+= 1
        // Re-sync selection titles if the live catalog remapped ids.
        let opts = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
        selectedModel = opts.model
        selectedAdvisor = opts.advisor
        selectedIntelligence = opts.intelligence
      }
    }
  }

  // MARK: - Command list section

  @ViewBuilder
  private func commandSection(_ title: String, _ commands: [VibeAgentSlashCommand]) -> some View {
    if !commands.isEmpty {
      Section(title) {
        ForEach(commands, id: \.name) { cmd in
          VibeToolCommandRow(command: cmd, appearance: appearance) {
            onSelectCommand?(cmd); onDismiss?()
          }
          .listRowBackground(rowFill)
        }
      }
    }
  }

  // MARK: - Inline setting row label

  @ViewBuilder
  private func settingRowLabel(title: String, systemImage: String, value: String) -> some View {
    HStack(spacing: 14) {
      Image(systemName: systemImage)
        .font(.system(size: 16, weight: .regular))
        .frame(width: 24)
        .foregroundStyle(text.opacity(0.85))

      Text(title)
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(text)

      Spacer()

      Text(value)
        .font(.system(size: 15))
        .foregroundStyle(textSecondary)
    }
    .padding(.vertical, 4)
  }

  // MARK: - Inner pages

  private var modelPage: some View {
    let primary = AgentBridgeSelectionStore.primaryModelChoices(provider: provider)
    let other = AgentBridgeSelectionStore.otherModelChoices(provider: provider)
    return List {
      Section {
        selectRow(
          title: "\(AgentBridgeSelectionStore.defaultModelTitle(provider: provider)) default",
          isSelected: selectedModel == nil
        ) {
          AgentBridgeSelectionStore.setModel(provider: provider, model: nil)
          selectedModel = nil
        }
        // Latest / CLI-current models only in the main list.
        ForEach(primary, id: \.value) { choice in
          selectRow(
            title: choice.title,
            isSelected: selectedModel == choice.value || (selectedModel != nil && selectedModel?.caseInsensitiveCompare(choice.value) == .orderedSame)
          ) {
            AgentBridgeSelectionStore.setModel(provider: provider, model: choice.value)
            selectedModel = choice.value
          }
        }
      } footer: {
        Text(modelCatalogFooter)
          .font(.system(size: 12))
          .foregroundStyle(textTertiary)
      }

      if !other.isEmpty {
        Section("Other Models") {
          ForEach(other, id: \.value) { choice in
            selectRow(
              title: choice.title,
              isSelected: selectedModel == choice.value || (selectedModel != nil && selectedModel?.caseInsensitiveCompare(choice.value) == .orderedSame)
            ) {
              AgentBridgeSelectionStore.setModel(provider: provider, model: choice.value)
              selectedModel = choice.value
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Model")
    .navigationBarTitleDisplayMode(.inline)
    .id(catalogEpoch)
    .onAppear {
      // Force status re-fetch so provider updates (new models) appear immediately.
      AgentBridgeSelectionStore.refreshModelsIfPossible()
    }
  }

  private var modelCatalogFooter: String {
    let live = AgentBridgeSelectionStore.liveModelChoices(provider: provider)
    if live.isEmpty {
      return "Showing seed list until the paired computer reports live models."
    }
    let source = live.first?.source ?? "live"
    return "Live from provider (\(source)) · \(live.count) models"
  }

  private var thinkingPage: some View {
    let levels = AgentBridgeSelectionStore.intelligenceChoices(
      provider: provider, model: selectedModel)
    return List {
      Section {
        if levels.isEmpty {
          Text("This model bakes thinking into the model name (pick another model row).")
            .font(.system(size: 14))
            .foregroundStyle(textSecondary)
        } else {
          ForEach(levels, id: \.self) { level in
            selectRow(title: level.title, isSelected: selectedIntelligence == level) {
              AgentBridgeSelectionStore.setIntelligence(level)
              selectedIntelligence = level
            }
          }
        }
      } footer: {
        Text("Thinking levels come from the provider for the selected model when available.")
          .font(.system(size: 12))
          .foregroundStyle(textTertiary)
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Thinking")
    .navigationBarTitleDisplayMode(.inline)
    .id(catalogEpoch)
    .onAppear {
      AgentBridgeSelectionStore.refreshModelsIfPossible()
    }
  }

  private var advisorPage: some View {
    List {
      Section {
        ForEach(AgentBridgeSelectionStore.advisorChoices(provider: provider), id: \.title) { choice in
          selectRow(title: choice.title, isSelected: selectedAdvisor == choice.value) {
            AgentBridgeSelectionStore.setAdvisor(
              provider: provider,
              advisor: choice.value ?? "off"
            )
            selectedAdvisor = choice.value
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Advisor")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var permissionPage: some View {
    List {
      Section {
        ForEach(AgentBridgeWorkMode.allCases, id: \.self) { mode in
          selectRow(title: mode.title, systemImage: mode.icon, isSelected: selectedWorkMode == mode) {
            AgentBridgeSelectionStore.setWorkMode(mode)
            selectedWorkMode = mode
            NotificationCenter.default.post(name: NSNotification.Name("AgentBridgeWorkModeChanged"), object: nil)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Permission")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder
  private func selectRow(
    title: String,
    systemImage: String? = nil,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 16, weight: .regular))
            .frame(width: 24)
            .foregroundStyle(text.opacity(0.85))
        }
        Text(title)
          .font(.system(size: 16, weight: .regular))
          .foregroundStyle(text)
        Spacer()
        if isSelected {
          Image(systemName: "checkmark")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(uiColor: appearance.primary))
        }
      }
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(rowFill)
  }
}

private struct VibeComposerAttachmentPill: View {
  let title: String
  let icon: String
  let appearance: VibeAgentKitChatAppearance

  var body: some View {
    VStack(alignment: .center, spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .regular))
      Text(title)
        .font(.system(size: 14, weight: .medium))
    }
    .frame(width: 105, height: 95)
    .background(
      appearance.isDark
        ? Color.white.opacity(0.08)
        : Color(uiColor: appearance.text).opacity(0.06)
    )
    .foregroundStyle(Color(uiColor: appearance.text))
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }
}

private struct VibeToolCommandRow: View {
  let command: VibeAgentSlashCommand
  let appearance: VibeAgentKitChatAppearance
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: paletteIcon(command))
          .font(.system(size: 16, weight: .regular))
          .frame(width: 24)
          .foregroundStyle(Color(uiColor: appearance.text).opacity(0.85))

        VStack(alignment: .leading, spacing: 2) {
          Text(command.display)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(Color(uiColor: appearance.text))

          if !command.subtitle.isEmpty {
            Text(command.subtitle)
              .font(.system(size: 12.5))
              .foregroundStyle(Color(uiColor: appearance.textSecondary))
          }
        }

        Spacer()
      }
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func paletteIcon(_ command: VibeAgentSlashCommand) -> String {
    if command.kind == .providerSlash { return "command" }
    if command.kind == .runOption { return "slider.horizontal.3" }
    return "terminal"
  }
}

// MARK: - Usage panel

struct VibeAgentUsageBucket: Identifiable {
  let id = UUID()
  let label: String
  let utilization: Int
  let resetsAt: String?
}

/// Live usage panel pushed from the tools sheet. Requests a structured snapshot from
/// the bridge (Claude subscription 5h/7-day limits + this chat's last-run tokens) and
/// renders it as progress bars — no chat bubble. Polls `ChatEngine` for the reply that
/// arrives as `agent-bridge-usage` keyed by our requestId.
/// Live usage panel (5h + weekly bars). Shared by the tools sheet and the chat
/// usage banner tap target so rate-limit hits open the same sheet for every agent.
struct VibeAgentUsagePanel: View {
  let chatId: String
  let provider: String
  let appearance: VibeAgentKitChatAppearance

  @State private var requestId: String?
  @State private var buckets: [VibeAgentUsageBucket] = []
  @State private var chatTokens: String?
  @State private var loading = true
  @State private var errorText: String?

  private var text: Color { Color(uiColor: appearance.text) }
  private var textSecondary: Color { Color(uiColor: appearance.textSecondary) }
  private var rowFill: Color {
    appearance.isDark ? Color.white.opacity(0.05) : Color(uiColor: appearance.surface)
  }

  var body: some View {
    List {
      if loading && buckets.isEmpty && errorText == nil {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Fetching usage from your Mac…")
              .font(.system(size: 15))
              .foregroundStyle(textSecondary)
          }
          .padding(.vertical, 6)
          .listRowBackground(rowFill)
        }
      }

      if !buckets.isEmpty {
        Section("SUBSCRIPTION LIMITS") {
          ForEach(buckets) { bucket in
            VibeUsageBar(bucket: bucket, appearance: appearance)
              .listRowBackground(rowFill)
          }
        }
      }

      if let chatTokens {
        Section("THIS CHAT (LAST RUN)") {
          Text(chatTokens)
            .font(.system(size: 14))
            .foregroundStyle(textSecondary)
            .listRowBackground(rowFill)
        }
      }

      if let errorText {
        Section {
          Text(errorText)
            .font(.system(size: 14))
            .foregroundStyle(textSecondary)
            .listRowBackground(rowFill)
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Usage")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear(perform: start)
    .onReceive(NotificationCenter.default.publisher(for: ChatEngine.didChangeNotification)) { note in
      guard
        let info = note.userInfo,
        (info["reason"] as? String) == "agentBridgeUsage",
        let rid = requestId,
        (info["requestId"] as? String) == rid
      else { return }
      ingest()
    }
  }

  private func start() {
    let result = ChatEngine.shared.requestAgentBridgeUsage([
      "chatId": chatId,
      "provider": provider,
    ])
    if let rid = result["requestId"] as? String, (result["accepted"] as? Bool) == true {
      requestId = rid
      // Fallback: if no reply lands, stop the spinner and explain.
      DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
        if loading && buckets.isEmpty {
          loading = false
          if errorText == nil {
            errorText = "Couldn't reach the bridge for usage. Make sure your Mac bridge is connected."
          }
        }
      }
    } else {
      loading = false
      errorText = "Usage is unavailable right now (\(result["reason"] as? String ?? "not connected"))."
    }
  }

  private func ingest() {
    guard let rid = requestId, let payload = ChatEngine.shared.latestAgentBridgeUsage(requestId: rid) else { return }
    loading = false
    if (payload["ok"] as? Bool) == false {
      errorText = (payload["message"] as? String) ?? "Usage request failed."
      return
    }
    guard let report = payload["report"] as? [String: Any] else {
      errorText = "The bridge returned no usage data."
      return
    }
    var parsed: [VibeAgentUsageBucket] = []
    if let rawBuckets = report["buckets"] as? [[String: Any]] {
      for b in rawBuckets {
        guard let label = b["label"] as? String else { continue }
        let util = (b["utilization"] as? Int) ?? Int((b["utilization"] as? Double) ?? 0)
        parsed.append(VibeAgentUsageBucket(label: label, utilization: util, resetsAt: b["resetsAt"] as? String))
      }
    }
    buckets = parsed
    if let chat = report["chat"] as? [String: Any] {
      chatTokens = Self.formatChatTokens(chat)
    }
    if parsed.isEmpty && chatTokens == nil {
      errorText = provider == "claude"
        ? "No subscription usage yet — sign in to Claude on your Mac, or run a task first."
        : "No usage recorded for this chat yet. Run a task first."
    }
  }

  private static func formatChatTokens(_ chat: [String: Any]) -> String? {
    func n(_ key: String) -> Int? {
      if let i = chat[key] as? Int { return i }
      if let d = chat[key] as? Double { return Int(d) }
      return nil
    }
    var parts: [String] = []
    if let i = n("inputTokens") { parts.append("input \(i)") }
    if let c = n("cachedInputTokens") { parts.append("cached \(c)") }
    if let o = n("outputTokens") { parts.append("output \(o)") }
    if let cost = chat["totalCostUsd"] as? Double { parts.append(String(format: "cost $%.4f", cost) ) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

private struct VibeUsageBar: View {
  let bucket: VibeAgentUsageBucket
  let appearance: VibeAgentKitChatAppearance

  private var pct: Double { max(0, min(100, Double(bucket.utilization))) }

  private var tint: Color {
    if pct >= 90 { return .red }
    if pct >= 70 { return .orange }
    return Color(uiColor: appearance.primary)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(bucket.label)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(Color(uiColor: appearance.text))
        Spacer()
        Text("\(bucket.utilization)%")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(tint)
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color(uiColor: appearance.text).opacity(0.12))
          Capsule()
            .fill(tint)
            .frame(width: max(6, geo.size.width * pct / 100))
        }
      }
      .frame(height: 8)
      if let reset = Self.resetText(bucket.resetsAt) {
        Text(reset)
          .font(.system(size: 12.5))
          .foregroundStyle(Color(uiColor: appearance.textSecondary))
      }
    }
    .padding(.vertical, 6)
  }

  private static func resetText(_ iso: String?) -> String? {
    guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return nil }
    let secs = date.timeIntervalSinceNow
    if secs <= 0 { return "resetting now" }
    let h = Int(secs) / 3600
    let m = (Int(secs) % 3600) / 60
    if h >= 24 { return "resets in \(h / 24)d \(h % 24)h" }
    if h >= 1 { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
  }
}
