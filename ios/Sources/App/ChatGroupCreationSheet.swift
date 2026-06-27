import SwiftUI

struct ChatGroupCreationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject private var coordinator: AppShellCoordinator

  let config: AppSessionConfig
  let onCreated: (ChatRoute) -> Void

  enum Step {
    case info
    case members
  }

  @State private var currentStep: Step = .info
  @State private var groupName = ""
  @State private var selectedMembers = Set<GroupMember>()
  @State private var searchQuery = ""
  @State private var searchResults: [ContactSearchUser] = []
  @State private var isSearching = false
  @State private var searchTask: Task<Void, Never>?
  @State private var isCreating = false
  @State private var errorMessage: String?

  @StateObject private var directoryModel = ContactDirectoryViewModel()

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  struct GroupMember: Identifiable, Hashable {
    let id: String
    let displayName: String
    let username: String?
    let avatarUri: String?
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if currentStep == .info {
          infoStepView
        } else {
          membersStepView
        }
      }
      .background(palette.background.ignoresSafeArea())
      .navigationTitle(currentStep == .info ? "New Group" : "Add Members")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          if currentStep == .members {
            Button {
              withAnimation { currentStep = .info }
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("Back")
              }
            }
          } else {
            Button("Cancel") {
              dismiss()
            }
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          if currentStep == .info {
            Button("Next") {
              withAnimation { currentStep = .members }
            }
            .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          } else {
            Button("Create") {
              Task { await createGroup() }
            }
            .disabled(isCreating)
          }
        }
      }
      .task {
        await directoryModel.refresh()
      }
    }
  }

  private var infoStepView: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Enter a name for the group and proceed to add members.")
        .font(.subheadline)
        .foregroundStyle(palette.secondaryText)
        .padding(.horizontal)
        .padding(.top)

      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Image(systemName: "person.3.fill")
            .font(.title2)
            .foregroundStyle(palette.accent)
            .frame(width: 50, height: 50)
            .background(palette.accent.opacity(0.12))
            .clipShape(Circle())

          TextField("Group name", text: $groupName)
            .font(.body)
            .submitLabel(.next)
            .onSubmit {
              if !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withAnimation { currentStep = .members }
              }
            }
        }
        .padding()
        .background(palette.card)
        .cornerRadius(12)
      }
      .padding(.horizontal)

      if let errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .padding(.horizontal)
      }

      Spacer()
    }
  }

  private var membersStepView: some View {
    VStack(spacing: 0) {
      // Selected members chips
      if !selectedMembers.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(Array(selectedMembers)) { member in
              HStack(spacing: 6) {
                Text(member.displayName)
                  .font(.footnote)
                  .fontWeight(.medium)
                  .foregroundStyle(palette.text)
                Button {
                  selectedMembers.remove(member)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(palette.secondaryText)
                }
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(palette.accent.opacity(0.15))
              .cornerRadius(16)
            }
          }
          .padding()
        }
        .frame(height: 56)
        .background(palette.background)
      }

      // Search bar
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(palette.secondaryText)
        TextField("Search friends to add...", text: $searchQuery)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onChange(of: searchQuery) { _, newValue in
            scheduleSearch(query: newValue)
          }
      }
      .padding(10)
      .background(palette.card)
      .cornerRadius(10)
      .padding(.horizontal)
      .padding(.bottom, 10)

      // List of members to select
      List {
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Section("Search Results") {
            if isSearching {
              HStack {
                Spacer()
                ProgressView()
                Spacer()
              }
              .listRowBackground(palette.card)
            } else if searchResults.isEmpty {
              Text("No users found.")
                .foregroundStyle(palette.secondaryText)
                .listRowBackground(palette.card)
            } else {
              ForEach(searchResults) { user in
                let member = GroupMember(id: user.userID, displayName: user.username, username: user.handle, avatarUri: user.profileImage)
                memberRow(member: member)
              }
            }
          }
        }

        Section("Recent Contacts") {
          let recentMembers = directoryModel.rows.compactMap { row -> GroupMember? in
            guard let peerId = row.peerUserId else { return nil }
            return GroupMember(id: peerId, displayName: row.title, username: nil, avatarUri: row.avatarUri)
          }

          if recentMembers.isEmpty {
            Text("No recent contacts found.")
              .foregroundStyle(palette.secondaryText)
              .listRowBackground(palette.card)
          } else {
            ForEach(recentMembers) { member in
              memberRow(member: member)
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)

      if let errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .padding()
      }
    }
  }

  @ViewBuilder
  private func memberRow(member: GroupMember) -> some View {
    let isSelected = selectedMembers.contains(member)
    Button {
      if isSelected {
        selectedMembers.remove(member)
      } else {
        selectedMembers.insert(member)
      }
    } label: {
      HStack(spacing: 12) {
        Circle()
          .fill(palette.accent.opacity(0.12))
          .frame(width: 36, height: 36)
          .overlay {
            Text(String(member.displayName.prefix(1)).uppercased())
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(palette.accent)
          }

        VStack(alignment: .leading, spacing: 2) {
          Text(member.displayName)
            .font(.body)
            .foregroundStyle(palette.text)
          if let username = member.username, !username.isEmpty {
            Text("@\(username)")
              .font(.footnote)
              .foregroundStyle(palette.secondaryText)
          }
        }

        Spacer()

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(isSelected ? palette.accent : palette.border)
      }
    }
    .buttonStyle(.plain)
    .listRowBackground(palette.card)
  }

  private func scheduleSearch(query: String) {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      searchResults = []
      isSearching = false
      return
    }

    isSearching = true
    searchTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 300_000_000)
      if Task.isCancelled { return }

      do {
        let results = try await ContactSearchService.search(config: config, query: trimmed)
        if !Task.isCancelled {
          self.searchResults = results
          self.isSearching = false
        }
      } catch {
        if !Task.isCancelled {
          self.searchResults = []
          self.isSearching = false
        }
      }
    }
  }

  @MainActor
  private func createGroup() async {
    isCreating = true
    errorMessage = nil
    defer { isCreating = false }

    do {
      let memberIds = Array(selectedMembers).map { $0.id }
      let result = try await ChatRoomCreateService.create(
        kind: .group,
        config: config,
        name: groupName,
        memberIds: memberIds
      )
      let route = ChatRoute(
        chatId: result.chatID,
        title: result.name,
        peerUserId: nil,
        avatarURI: nil,
        isGroup: true,
        initialRows: []
      )
      onCreated(route)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
