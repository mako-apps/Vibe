import SwiftUI
import PhotosUI

struct ChatGroupCreationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject private var coordinator: AppShellCoordinator

  let config: AppSessionConfig
  let homeRows: [ChatHomeListRow]
  let onCreated: (ChatRoute) -> Void

  enum Step: Hashable {
    case info
  }

  @State private var path = NavigationPath()
  @State private var groupName = ""
  @State private var selectedMembers = Set<ContactSearchUser>()
  @State private var searchQuery = ""
  @FocusState private var isQueryFieldFocused: Bool
  @State private var isSearchPresented = false
  @State private var searchResults: [ContactSearchUser] = []
  @State private var isSearching = false
  @State private var searchTask: Task<Void, Never>?
  @State private var isCreating = false
  @State private var errorMessage: String?
  @State private var avatarItem: PhotosPickerItem?
  @State private var avatarImage: Image?
  @State private var avatarData: Data?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private func contactUser(for row: ChatHomeListRow) -> ContactSearchUser {
    ContactSearchUser(payload: [
      "userId": row.peerUserId ?? row.chatId,
      "username": row.title,
      "profileImage": row.avatarUri ?? "",
      "isAgent": row.isBuiltInAgentSurface || row.isBridgeAgentSurface,
      "tier": row.isGoldTier ? "gold" : "free"
    ])!
  }

  var body: some View {
    NavigationStack(path: $path) {
      membersStepView
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("New Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              dismiss()
            } label: {
              Image(systemName: "xmark")
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button("Next") {
              path.append(Step.info)
            }
            .disabled(selectedMembers.isEmpty)
          }
        }
        .navigationDestination(for: Step.self) { step in
          if step == .info {
            infoStepView
              .background(palette.background.ignoresSafeArea())
              .navigationTitle("New Group")
              .navigationBarTitleDisplayMode(.inline)
              .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                  Button("Create") {
                    Task { await createGroup() }
                  }
                  .disabled(isCreating || groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
              }
          }
        }
        .overlay {
          if isCreating {
            ZStack {
              Color.black.opacity(0.3).ignoresSafeArea()
              ProgressView()
                .padding()
                .background(palette.card)
                .cornerRadius(8)
            }
          }
        }
    }
  }

  private var membersStepView: some View {
    VStack(spacing: 0) {
      if let errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .padding()
      }

      List {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
          if isSearching {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
            .listRowBackground(Color.clear)
          } else if searchResults.isEmpty {
            Text("No users found.")
              .foregroundStyle(palette.secondaryText)
              .listRowBackground(Color.clear)
          } else {
            groupedUsersSection(users: searchResults)
          }
        } else {
          groupedUsersSection(users: homeRows.map(contactUser(for:)))
        }
      }
      .listStyle(.plain)
      .searchable(
        text: $searchQuery,
        isPresented: $isSearchPresented,
        placement: .navigationBarDrawer(displayMode: .automatic),
        prompt: "Search friends to add..."
      )
      .onChange(of: searchQuery) { _, newValue in
        scheduleSearch(query: newValue)
      }
    }
  }

  private func groupedUsersSection(users: [ContactSearchUser]) -> some View {
    var uniqueUsers: [ContactSearchUser] = []
    var seenIDs = Set<String>()
    for user in users {
      if !seenIDs.contains(user.userID) {
        seenIDs.insert(user.userID)
        uniqueUsers.append(user)
      }
    }
    let grouped = Dictionary(grouping: uniqueUsers) { user in
      String(user.username.prefix(1)).uppercased()
    }
    let sortedKeys = grouped.keys.sorted()

    return ForEach(sortedKeys, id: \.self) { letter in
      Section(letter) {
        ForEach(grouped[letter]!) { user in
          memberRow(user: user)
        }
      }
    }
  }

  @ViewBuilder
  private func memberRow(user: ContactSearchUser) -> some View {
    let isSelected = selectedMembers.contains(user)
    Button {
      if isSelected {
        selectedMembers.remove(user)
      } else {
        selectedMembers.insert(user)
      }
    } label: {
      ContactSearchResultRow(user: user, isSaved: isSelected, palette: palette)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var infoStepView: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Enter a name and add a profile image for the group.")
        .font(.subheadline)
        .foregroundStyle(palette.secondaryText)
        .padding(.horizontal)
        .padding(.top)

      VStack(spacing: 0) {
        HStack(spacing: 16) {
          PhotosPicker(selection: $avatarItem, matching: .images) {
            if let avatarImage {
              avatarImage
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(Circle())
            } else {
              Image(systemName: "camera.fill")
                .font(.title2)
                .foregroundStyle(palette.accent)
                .frame(width: 56, height: 56)
                .background(palette.accent.opacity(0.12))
                .clipShape(Circle())
            }
          }
          .buttonStyle(.plain)

          TextField("Group name", text: $groupName)
            .font(.body)
            .submitLabel(.done)
        }
        .padding()
        .background(palette.card)
        .cornerRadius(12)
      }
      .padding(.horizontal)
      
      Text("Selected Members")
        .font(.headline)
        .padding(.horizontal)
        .padding(.top, 10)

      List {
        ForEach(Array(selectedMembers)) { user in
          ContactSearchResultRow(user: user, isSaved: false, palette: palette)
        }
      }
      .listStyle(.plain)
      .frame(maxHeight: .infinity)

      if let errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .padding(.horizontal)
      }
    }
    .onChange(of: avatarItem) { _, newItem in
      Task {
        guard let data = try? await newItem?.loadTransferable(type: Data.self) else { return }
        guard let uiImage = UIImage(data: data) else { return }
        self.avatarData = data
        self.avatarImage = Image(uiImage: uiImage)
      }
    }
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
      var remoteAvatarUrl: String? = nil
      if let avatarData {
        remoteAvatarUrl = try await ChatRoomCreateService.uploadAvatar(imageData: avatarData, config: config)
      }

      let members = Array(selectedMembers)
      let memberIds = members.map { $0.userID }
      let result = try await ChatRoomCreateService.create(
        kind: .group,
        config: config,
        name: groupName,
        memberIds: memberIds,
        avatarUrl: remoteAvatarUrl
      )

      // Known immediately from what we just picked — no need to wait for the next
      // home-list refresh before the group profile shows real members.
      let ownMember: [String: Any] = [
        "userId": config.userID,
        "name": config.name ?? config.username ?? "You",
        "role": "owner"
      ]
      let otherMembers: [[String: Any]] = members.map {
        ["userId": $0.userID, "name": $0.username, "role": "member"]
      }

      let route = ChatRoute(
        chatId: result.chatID,
        title: result.name,
        peerUserId: nil,
        avatarURI: remoteAvatarUrl,
        isGroup: true,
        initialRows: [],
        members: [ownMember] + otherMembers
      )
      onCreated(route)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

/// Member picker for an *existing* group, pushed from the group profile's
/// "Members" screen. Same search/selection building blocks as
/// `ChatGroupCreationSheet` above, minus the name/avatar step — adding
/// members doesn't create a new room.
struct AddGroupMembersSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  let config: AppSessionConfig
  let chatId: String
  let excludedUserIds: Set<String>
  let onAdded: ([[String: Any]]) -> Void

  @State private var selectedMembers = Set<ContactSearchUser>()
  @State private var searchQuery = ""
  @State private var searchResults: [ContactSearchUser] = []
  @State private var isSearching = false
  @State private var searchTask: Task<Void, Never>?
  @State private var isSaving = false
  @State private var errorMessage: String?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var candidates: [ContactSearchUser] {
    searchResults.filter { !excludedUserIds.contains($0.userID) }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .padding()
        }

        List {
          if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Search for someone to add.")
              .foregroundStyle(palette.secondaryText)
              .listRowBackground(Color.clear)
          } else if isSearching {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
            .listRowBackground(Color.clear)
          } else if candidates.isEmpty {
            Text("No users found.")
              .foregroundStyle(palette.secondaryText)
              .listRowBackground(Color.clear)
          } else {
            ForEach(candidates) { user in
              memberRow(user: user)
            }
          }
        }
        .listStyle(.plain)
      }
      .background(palette.background.ignoresSafeArea())
      .navigationTitle("Add Members")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchQuery, prompt: "Search people...")
      .onChange(of: searchQuery) { _, newValue in
        scheduleSearch(query: newValue)
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Add") {
            Task { await addSelectedMembers() }
          }
          .disabled(selectedMembers.isEmpty || isSaving)
        }
      }
      .overlay {
        if isSaving {
          ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            ProgressView()
              .padding()
              .background(palette.card)
              .cornerRadius(8)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func memberRow(user: ContactSearchUser) -> some View {
    let isSelected = selectedMembers.contains(user)
    Button {
      if isSelected {
        selectedMembers.remove(user)
      } else {
        selectedMembers.insert(user)
      }
    } label: {
      ContactSearchResultRow(user: user, isSaved: isSelected, palette: palette)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
  private func addSelectedMembers() async {
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }

    let selected = Array(selectedMembers)
    do {
      let results = try await GroupMembersUpdateService.addMembers(
        chatId: chatId,
        memberIds: selected.map(\.userID),
        config: config
      )
      let addedIds = Set(results.filter(\.added).map(\.userId))
      guard !addedIds.isEmpty else {
        errorMessage = "Couldn't add the selected members."
        return
      }
      let addedRaw: [[String: Any]] = selected
        .filter { addedIds.contains($0.userID) }
        .map { ["userId": $0.userID, "name": $0.username, "role": "member"] }
      onAdded(addedRaw)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

/// Owner/admin editor for an existing group's identity — name, photo and
/// description. Saves via `GroupUpdateService.update` (PUT /group/:id) and hands
/// the fresh values back so the open profile + home row update without waiting
/// for a home reload.
struct GroupEditSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  let config: AppSessionConfig
  let chatId: String
  let initialAvatarUri: String?
  let onSaved: (_ name: String, _ description: String, _ avatarUrl: String?) -> Void

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
    initialName: String,
    initialDescription: String,
    initialAvatarUri: String?,
    onSaved: @escaping (String, String, String?) -> Void
  ) {
    self.config = config
    self.chatId = chatId
    self.initialAvatarUri = initialAvatarUri
    self.onSaved = onSaved
    _name = State(initialValue: initialName)
    _descriptionText = State(initialValue: initialDescription)
  }

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 16) {
          PhotosPicker(selection: $avatarItem, matching: .images) {
            avatarThumb
          }
          .buttonStyle(.plain)

          TextField("Group name", text: $name)
            .font(.body)
            .submitLabel(.done)
        }
        .padding()
        .background(palette.card)
        .cornerRadius(12)
        .padding(.horizontal)

        VStack(alignment: .leading, spacing: 6) {
          Text("Description")
            .font(.headline)
            .padding(.horizontal, 4)
          TextField("What's this group about?", text: $descriptionText, axis: .vertical)
            .lineLimit(2...5)
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
      .padding(.top)
      .background(palette.background.ignoresSafeArea())
      .navigationTitle("Edit Group")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button { dismiss() } label: { Image(systemName: "xmark") }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Save") { Task { await save() } }
            .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .overlay {
        if isSaving {
          ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            ProgressView()
              .padding()
              .background(palette.card)
              .cornerRadius(8)
          }
        }
      }
      .onChange(of: avatarItem) { _, newItem in
        Task {
          guard let data = try? await newItem?.loadTransferable(type: Data.self) else { return }
          guard let uiImage = UIImage(data: data) else { return }
          self.avatarData = data
          self.avatarImage = Image(uiImage: uiImage)
        }
      }
    }
  }

  @ViewBuilder
  private var avatarThumb: some View {
    if let avatarImage {
      avatarImage
        .resizable()
        .scaledToFill()
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    } else if let uri = initialAvatarUri?.trimmingCharacters(in: .whitespacesAndNewlines),
      !uri.isEmpty, let url = URL(string: uri) {
      AsyncImage(url: url) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Image(systemName: "camera.fill")
          .font(.title2)
          .foregroundStyle(palette.accent)
      }
      .frame(width: 56, height: 56)
      .clipShape(Circle())
    } else {
      Image(systemName: "camera.fill")
        .font(.title2)
        .foregroundStyle(palette.accent)
        .frame(width: 56, height: 56)
        .background(palette.accent.opacity(0.12))
        .clipShape(Circle())
    }
  }

  private func save() async {
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      var remoteAvatarUrl: String? = nil
      if let avatarData {
        remoteAvatarUrl = try await ChatRoomCreateService.uploadAvatar(
          imageData: avatarData, config: config)
      }
      let result = try await GroupUpdateService.update(
        chatId: chatId,
        name: name,
        description: descriptionText,
        avatarUrl: remoteAvatarUrl,
        config: config
      )
      onSaved(
        result.name ?? name.trimmingCharacters(in: .whitespacesAndNewlines),
        result.description ?? descriptionText,
        result.avatarUrl ?? remoteAvatarUrl ?? initialAvatarUri
      )
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
