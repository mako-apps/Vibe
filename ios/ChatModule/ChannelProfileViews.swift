import PhotosUI
import SwiftUI

// MARK: - Channel roster (admins / subscribers)

struct ChannelMemberListPage: View {
  let title: String
  let members: [ChannelProfileService.Member]
  let emptyText: String

  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    List {
      if members.isEmpty {
        Text(emptyText)
          .font(.system(size: 15))
          .foregroundStyle(palette.secondaryText)
          .listRowBackground(Color.clear)
      } else {
        ForEach(members, id: \.userId) { member in
          HStack(spacing: 12) {
            Circle()
              .fill(palette.accent.opacity(0.18))
              .frame(width: 40, height: 40)
              .overlay {
                Text(String(member.name.prefix(1)).uppercased())
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundStyle(palette.accent)
              }
            VStack(alignment: .leading, spacing: 2) {
              Text(member.name)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
              Text(member.role.capitalized)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
            }
            Spacer()
          }
          .listRowBackground(palette.card)
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - Recent actions

struct ChannelRecentActionsPage: View {
  let actions: [ChannelProfileService.RecentAction]

  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    List {
      if actions.isEmpty {
        Text("No recent actions yet")
          .font(.system(size: 15))
          .foregroundStyle(palette.secondaryText)
          .listRowBackground(Color.clear)
      } else {
        ForEach(actions) { action in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(action.fromName ?? action.fromId ?? "System")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
              Spacer()
              Text(Self.timeLabel(action.timestampMs))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
            }
            Text(action.text.isEmpty ? action.type : action.text)
              .font(.system(size: 14))
              .foregroundStyle(palette.secondaryText)
              .lineLimit(3)
          }
          .listRowBackground(palette.card)
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Recent actions")
    .navigationBarTitleDisplayMode(.inline)
  }

  private static func timeLabel(_ ms: Int64) -> String {
    guard ms > 0 else { return "" }
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
    let f = DateFormatter()
    f.doesRelativeDateFormatting = true
    f.dateStyle = .short
    f.timeStyle = .short
    return f.string(from: date)
  }
}

// MARK: - Channel settings (page, not sheet)

struct ChannelSettingsPage: View {
  let chatId: String
  let channelName: String
  let canManage: Bool
  @Binding var settings: ChannelProfileService.Settings
  let onEditName: () -> Void
  let onOpenAppearance: () -> Void
  let onOpenRecentActions: () -> Void
  let onSettingsChanged: (ChannelProfileService.Settings) -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isBusy = false
  @State private var errorMessage: String?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    List {
      Section {
        Button(action: onEditName) {
          settingsRow(
            title: "Channel name",
            subtitle: channelName,
            showsChevron: canManage
          )
        }
        .disabled(!canManage)

        if canManage {
          Picker("Channel type", selection: channelTypeBinding) {
            Text("Public").tag("public")
            Text("Private").tag("private")
          }

          if settings.channelType == "public" {
            TextField("Public link name", text: publicSlugBinding)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }

          Button("Apply channel type") {
            Task { await persist(settings) }
          }
          .disabled(
            settings.channelType == "public"
              && (settings.publicSlug ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )

          if settings.channelType == "private" {
            Button {
              Task { await rotateInvite() }
            } label: {
              settingsRow(
                title: "Invite link",
                subtitle: settings.inviteLink?.isEmpty == false
                  ? settings.inviteLink!
                  : "Create invite link",
                showsChevron: true
              )
            }
          }

          Toggle("Approve new subscribers", isOn: joinApprovalBinding)
          Toggle("Restrict saving content", isOn: restrictSavingBinding)
          Toggle("Discussions", isOn: discussionsBinding)
          Toggle("Reactions", isOn: reactionsBinding)
          Toggle("Direct messages", isOn: dmsBinding)
          Toggle("Auto-translate", isOn: translateBinding)
        } else {
          settingsRow(
            title: "Channel type",
            subtitle: settings.channelType.capitalized,
            showsChevron: false
          )
        }

        Button(action: onOpenAppearance) {
          settingsRow(title: "Appearance", subtitle: "Photo & poster", showsChevron: true)
        }

        Button(action: onOpenRecentActions) {
          settingsRow(title: "Recent actions", subtitle: "Messages & events", showsChevron: true)
        }
      }

      if let errorMessage {
        Section {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Channel settings")
    .navigationBarTitleDisplayMode(.inline)
    .overlay {
      if isBusy {
        ProgressView().padding().background(.ultraThinMaterial).cornerRadius(10)
      }
    }
  }

  private var channelTypeBinding: Binding<String> {
    Binding(
      get: { settings.channelType },
      set: { next in
        var s = settings
        s.channelType = next
        settings = s
      }
    )
  }

  private var publicSlugBinding: Binding<String> {
    Binding(
      get: { settings.publicSlug ?? "" },
      set: { next in
        var s = settings
        s.publicSlug = ChannelCreationSheet.normalizePublicSlug(next)
        settings = s
      }
    )
  }

  private var joinApprovalBinding: Binding<Bool> {
    Binding(
      get: { settings.joinApprovalRequired },
      set: { next in
        var s = settings
        s.joinApprovalRequired = next
        settings = s
        Task { await persist(s) }
      }
    )
  }

  private var restrictSavingBinding: Binding<Bool> {
    Binding(
      get: { settings.restrictSavingContent },
      set: { next in
        var s = settings
        s.restrictSavingContent = next
        settings = s
        Task { await persist(s) }
      }
    )
  }

  private var discussionsBinding: Binding<Bool> {
    Binding(
      get: { settings.discussionsEnabled },
      set: { next in
        var s = settings
        s.discussionsEnabled = next
        settings = s
        Task { await persist(s) }
      }
    )
  }

  private var reactionsBinding: Binding<Bool> {
    Binding(
      get: { settings.reactionsEnabled },
      set: { next in
        var s = settings
        s.reactionsEnabled = next
        settings = s
        Task { await persist(s) }
      }
    )
  }

  private var dmsBinding: Binding<Bool> {
    Binding(
      get: { settings.allowDirectMessages },
      set: { next in
        var s = settings
        s.allowDirectMessages = next
        settings = s
        Task { await persist(s) }
      }
    )
  }

  private var translateBinding: Binding<Bool> {
    Binding(
      get: { settings.autoTranslateEnabled },
      set: { next in
        var s = settings
        s.autoTranslateEnabled = next
        settings = s
        Task { await persist(s) }
      }
    )
  }

  @ViewBuilder
  private func settingsRow(title: String, subtitle: String, showsChevron: Bool) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(.footnote)
          .foregroundStyle(palette.secondaryText)
          .lineLimit(2)
      }
      Spacer()
      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(palette.secondaryText)
      }
    }
  }

  @MainActor
  private func persist(_ next: ChannelProfileService.Settings) async {
    guard let config = AppSessionConfig.current else { return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      let profile = try await ChannelProfileService.update(
        chatId: chatId, settings: next, config: config)
      settings = profile.settings
      onSettingsChanged(profile.settings)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func rotateInvite() async {
    guard let config = AppSessionConfig.current else { return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      let next = try await ChannelProfileService.rotateInviteLink(chatId: chatId, config: config)
      settings = next
      onSettingsChanged(next)
      if let link = next.inviteLink, !link.isEmpty {
        UIPasteboard.general.string = link
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Room edit page (group/channel) — navigation page, not sheet

struct RoomEditPage: View {
  let config: AppSessionConfig
  let chatId: String
  let isChannel: Bool
  let initialName: String
  let initialDescription: String
  let initialAvatarUri: String?
  let onSaved: (_ name: String, _ description: String, _ avatarUrl: String?) -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var name: String
  @State private var descriptionText: String
  @State private var avatarItem: PhotosPickerItem?
  @State private var avatarImage: Image?
  @State private var avatarData: Data?
  @State private var isSaving = false
  @State private var errorMessage: String?

  init(
    config: AppSessionConfig,
    chatId: String,
    isChannel: Bool,
    initialName: String,
    initialDescription: String,
    initialAvatarUri: String?,
    onSaved: @escaping (String, String, String?) -> Void
  ) {
    self.config = config
    self.chatId = chatId
    self.isChannel = isChannel
    self.initialName = initialName
    self.initialDescription = initialDescription
    self.initialAvatarUri = initialAvatarUri
    self.onSaved = onSaved
    _name = State(initialValue: initialName)
    _descriptionText = State(initialValue: initialDescription)
  }

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 16) {
          PhotosPicker(selection: $avatarItem, matching: .images) {
            if let avatarImage {
              avatarImage
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(Circle())
            } else {
              Image(systemName: "camera.fill")
                .font(.title2)
                .foregroundStyle(palette.accent)
                .frame(width: 72, height: 72)
                .background(palette.accent.opacity(0.12))
                .clipShape(Circle())
            }
          }
          .buttonStyle(.plain)

          TextField(isChannel ? "Channel name" : "Group name", text: $name)
            .font(.body)
        }
        .padding()
        .background(palette.card)
        .cornerRadius(12)

        VStack(alignment: .leading, spacing: 6) {
          Text("Description")
            .font(.headline)
          TextField(
            isChannel ? "What's this channel about?" : "What's this group about?",
            text: $descriptionText,
            axis: .vertical
          )
          .lineLimit(3...8)
          .padding()
          .background(palette.card)
          .cornerRadius(12)
        }

        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
      .padding()
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle(isChannel ? "Edit channel" : "Edit group")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Save") { Task { await save() } }
          .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .overlay {
      if isSaving {
        ProgressView().padding().background(.ultraThinMaterial).cornerRadius(10)
      }
    }
    .onChange(of: avatarItem) { _, newItem in
      Task {
        guard let data = try? await newItem?.loadTransferable(type: Data.self) else { return }
        guard let uiImage = UIImage(data: data) else { return }
        avatarData = data
        avatarImage = Image(uiImage: uiImage)
      }
    }
  }

  @MainActor
  private func save() async {
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      var remoteAvatar: String? = nil
      if let avatarData {
        remoteAvatar = try await ChatRoomCreateService.uploadAvatar(
          imageData: avatarData, config: config)
      }
      if isChannel {
        _ = try await ChannelProfileService.update(
          chatId: chatId,
          name: name.trimmingCharacters(in: .whitespacesAndNewlines),
          description: descriptionText,
          avatarUrl: remoteAvatar,
          config: config
        )
      } else {
        _ = try await GroupUpdateService.update(
          chatId: chatId,
          name: name.trimmingCharacters(in: .whitespacesAndNewlines),
          description: descriptionText,
          avatarUrl: remoteAvatar,
          config: config
        )
      }
      onSaved(
        name.trimmingCharacters(in: .whitespacesAndNewlines),
        descriptionText,
        remoteAvatar ?? initialAvatarUri
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Channel agent administrators

struct ChannelAgentManagementPage: View {
  let chatId: String
  let onCreateAgent: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var assignments: [ChannelProfileService.AgentAssignment] = []
  @State private var ownedAgents: [ChannelProfileService.OwnedAgent] = []
  @State private var isLoading = true
  @State private var busyAgentId: String?
  @State private var errorMessage: String?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  private var unattachedAgents: [ChannelProfileService.OwnedAgent] {
    let attached = Set(assignments.map(\.agentId))
    return ownedAgents.filter { !attached.contains($0.id) }
  }

  var body: some View {
    List {
      Section {
        Button(action: onCreateAgent) {
          Label("Create an agent", systemImage: "plus.circle.fill")
            .font(.system(size: 16, weight: .semibold))
        }
      } footer: {
        Text("Agents are standalone identities. This channel only grants a narrowed set of their tools, output modes, and triggers.")
      }

      Section("Agent administrators") {
        if isLoading {
          HStack { Spacer(); ProgressView(); Spacer() }
        } else if assignments.isEmpty {
          Text("No channel agents yet")
            .foregroundStyle(palette.secondaryText)
        } else {
          ForEach(assignments) { assignment in
            NavigationLink {
              ChannelAgentPolicyPage(
                chatId: chatId,
                assignment: assignment,
                baseAgent: ownedAgents.first(where: { $0.id == assignment.agentId }),
                onSaved: { updated in
                  replace(updated)
                },
                onDetached: {
                  assignments.removeAll { $0.agentId == assignment.agentId }
                }
              )
            } label: {
              agentRow(
                name: assignment.displayName,
                subtitle: assignment.status == "active" ? "Agent admin" : "Disabled",
                isBusy: false
              )
            }
          }
        }
      }

      if !unattachedAgents.isEmpty {
        Section("Available agents") {
          ForEach(unattachedAgents) { agent in
            Button {
              Task { await attach(agent) }
            } label: {
              agentRow(
                name: agent.displayName,
                subtitle: agent.status == "published" ? "Add as agent admin" : "Publish before adding",
                isBusy: busyAgentId == agent.id
              )
            }
            .disabled(busyAgentId != nil || agent.status != "published")
          }
        }
      }

      if let errorMessage {
        Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Channel agents")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { await load() }
  }

  @ViewBuilder
  private func agentRow(name: String, subtitle: String, isBusy: Bool) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "sparkles")
        .foregroundStyle(palette.accent)
        .frame(width: 38, height: 38)
        .background(palette.accent.opacity(0.14), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(name).foregroundStyle(.primary)
        Text(subtitle).font(.caption).foregroundStyle(palette.secondaryText)
      }
      Spacer()
      if isBusy { ProgressView() }
    }
  }

  @MainActor
  private func load() async {
    guard let config = AppSessionConfig.current else { return }
    isLoading = assignments.isEmpty
    errorMessage = nil
    do {
      async let assignmentRequest = ChannelProfileService.fetchAgentAssignments(
        chatId: chatId, config: config)
      async let agentRequest = ChannelProfileService.fetchOwnedAgents(config: config)
      let (nextAssignments, nextAgents) = try await (assignmentRequest, agentRequest)
      assignments = nextAssignments
      ownedAgents = nextAgents
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  @MainActor
  private func attach(_ agent: ChannelProfileService.OwnedAgent) async {
    guard let config = AppSessionConfig.current else { return }
    busyAgentId = agent.id
    errorMessage = nil
    defer { busyAgentId = nil }
    do {
      let assignment = try await ChannelProfileService.attachAgent(
        chatId: chatId, agent: agent, config: config)
      replace(assignment)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func replace(_ assignment: ChannelProfileService.AgentAssignment) {
    assignments.removeAll { $0.agentId == assignment.agentId }
    assignments.append(assignment)
    assignments.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
  }
}

private struct ChannelAgentPolicyPage: View {
  let chatId: String
  let assignment: ChannelProfileService.AgentAssignment
  let baseAgent: ChannelProfileService.OwnedAgent?
  let onSaved: (ChannelProfileService.AgentAssignment) -> Void
  let onDetached: () -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var allowedTools: Set<String>
  @State private var allowedOutputModes: Set<String>
  @State private var triggerType: String
  @State private var intervalHours: Int
  @State private var instructions: String
  @State private var isActive: Bool
  @State private var isBusy = false
  @State private var errorMessage: String?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }
  private var toolChoices: [String] {
    let base = baseAgent?.enabledTools ?? assignment.allowedTools
    return Array(Set(base)).sorted()
  }
  private var outputChoices: [String] {
    let base = baseAgent?.outputModes ?? assignment.allowedOutputModes
    let values = base.isEmpty ? ["text"] : base
    return Array(Set(values)).sorted()
  }

  init(
    chatId: String,
    assignment: ChannelProfileService.AgentAssignment,
    baseAgent: ChannelProfileService.OwnedAgent?,
    onSaved: @escaping (ChannelProfileService.AgentAssignment) -> Void,
    onDetached: @escaping () -> Void
  ) {
    self.chatId = chatId
    self.assignment = assignment
    self.baseAgent = baseAgent
    self.onSaved = onSaved
    self.onDetached = onDetached
    _allowedTools = State(initialValue: Set(assignment.allowedTools))
    _allowedOutputModes = State(initialValue: Set(assignment.allowedOutputModes))
    let trigger = (assignment.triggerConfig["type"] as? String) ?? "manual"
    _triggerType = State(initialValue: trigger)
    let minutes = (assignment.triggerConfig["everyMinutes"] as? NSNumber)?.intValue
      ?? (assignment.triggerConfig["every_minutes"] as? NSNumber)?.intValue
      ?? 240
    _intervalHours = State(initialValue: max(1, minutes / 60))
    _instructions = State(
      initialValue: (assignment.permissions["instructions"] as? String) ?? "")
    _isActive = State(initialValue: assignment.status == "active")
  }

  var body: some View {
    Form {
      Section {
        Toggle("Enabled", isOn: $isActive)
        TextField(
          "Channel-specific instructions",
          text: $instructions,
          axis: .vertical
        )
        .lineLimit(3...8)
      } header: {
        Text("Channel role")
      } footer: {
        Text("These instructions are appended only when this agent works in this channel; its global identity and prompt remain unchanged.")
      }

      Section {
        ForEach(outputChoices, id: \.self) { mode in
          Toggle(modeLabel(mode), isOn: membership(mode, in: $allowedOutputModes))
        }
      } header: {
        Text("Allowed output")
      } footer: {
        Text("Media includes images, files, music, and video. Voice requires the agent's voice capability.")
      }

      Section {
        if toolChoices.isEmpty {
          Text("This agent has no tools enabled.").foregroundStyle(palette.secondaryText)
        } else {
          ForEach(toolChoices, id: \.self) { tool in
            Toggle(toolLabel(tool), isOn: membership(tool, in: $allowedTools))
          }
        }
      } header: {
        Text("Allowed tools")
      } footer: {
        Text("Channel permissions can only narrow the agent's own tools. Connected and custom tools remain scoped to the agent owner.")
      }

      Section {
        Picker("Run", selection: $triggerType) {
          Text("When mentioned").tag("manual")
          Text("On connected events").tag("event")
          Text("On an interval").tag("interval")
        }
        if triggerType == "interval" {
          Stepper("Every \(intervalHours) hour\(intervalHours == 1 ? "" : "s")", value: $intervalHours, in: 1...24)
        }
      } header: {
        Text("Trigger")
      } footer: {
        Text("Event triggers use the agent's connected apps and event filters. Interval execution is stored as channel policy and runs through the same narrowed permissions.")
      }

      if let errorMessage {
        Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
      }

      Section {
        Button("Remove agent from channel", role: .destructive) {
          Task { await detach() }
        }
      }
    }
    .navigationTitle(assignment.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Save") { Task { await save() } }
          .disabled(isBusy)
      }
    }
    .overlay { if isBusy { ProgressView().padding().background(.ultraThinMaterial).cornerRadius(10) } }
  }

  private func membership(_ value: String, in values: Binding<Set<String>>) -> Binding<Bool> {
    Binding(
      get: { values.wrappedValue.contains(value) },
      set: { enabled in
        if enabled { values.wrappedValue.insert(value) }
        else { values.wrappedValue.remove(value) }
      }
    )
  }

  private func modeLabel(_ value: String) -> String {
    switch value { case "text": return "Text"; case "media": return "Media & music"; case "voice": return "Voice"; default: return value }
  }

  private func toolLabel(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: " ").capitalized
  }

  @MainActor
  private func save() async {
    guard let config = AppSessionConfig.current else { return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    var trigger: [String: Any] = ["type": triggerType]
    if triggerType == "interval" { trigger["everyMinutes"] = intervalHours * 60 }
    do {
      let updated = try await ChannelProfileService.updateAgentAssignment(
        chatId: chatId,
        agentId: assignment.agentId,
        allowedTools: allowedTools.sorted(),
        allowedOutputModes: allowedOutputModes.sorted(),
        triggerConfig: trigger,
        permissions: ["instructions": instructions.trimmingCharacters(in: .whitespacesAndNewlines)],
        status: isActive ? "active" : "disabled",
        config: config
      )
      onSaved(updated)
      AppToastController.shared.show("Channel agent updated.")
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func detach() async {
    guard let config = AppSessionConfig.current else { return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await ChannelProfileService.detachAgent(
        chatId: chatId, agentId: assignment.agentId, config: config)
      onDetached()
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
