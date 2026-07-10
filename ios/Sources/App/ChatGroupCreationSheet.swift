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
/// Push destination (NavigationStack) for adding members — same material/API as
/// New Chat / `ContactSearchView`: plain List, A–Z sections, home-style rows.
struct AddGroupMembersPickerView: View {
  @Environment(\.colorScheme) private var colorScheme

  let config: AppSessionConfig
  let chatId: String
  let excludedUserIds: Set<String>
  let onAdded: ([[String: Any]]) -> Void

  @State private var selectedMembers = Set<ContactSearchUser>()
  @State private var searchQuery = ""
  @State private var searchResults: [ContactSearchUser] = []
  @State private var isSearching = false
  @State private var hasSearched = false
  @State private var searchTask: Task<Void, Never>?
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var isSearchPresented = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var candidates: [ContactSearchUser] {
    searchResults.filter { !excludedUserIds.contains($0.userID) }
  }

  private var selectedOrdered: [ContactSearchUser] {
    Array(selectedMembers).sorted {
      $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
    }
  }

  var body: some View {
    List {
      if !selectedOrdered.isEmpty {
        Section("Selected") {
          ForEach(selectedOrdered) { user in
            ContactSearchResultRow(user: user, isSaved: true, palette: palette)
              .contentShape(Rectangle())
              .onTapGesture { selectedMembers.remove(user) }
              .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
              .listRowBackground(Color.clear)
          }
        }
      }

      if let errorMessage {
        Section {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .listRowBackground(Color.clear)
        }
      }

      if !candidates.isEmpty {
        groupedUsersSection(users: candidates)
      } else if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Section {
          Text("Search for people to add. They join as members.")
            .font(.system(size: 14))
            .foregroundStyle(palette.secondaryText)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
      } else if isSearching {
        Section {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        }
      } else if hasSearched {
        Section {
          Text("No people found.")
            .foregroundStyle(palette.secondaryText)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Add Members")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .searchable(
      text: $searchQuery,
      isPresented: $isSearchPresented,
      placement: .navigationBarDrawer(displayMode: .automatic),
      prompt: "Username, phone, or ID"
    )
    .onChange(of: searchQuery) { _, newValue in
      scheduleSearch(query: newValue)
    }
    .onAppear { isSearchPresented = true }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(selectedOrdered.isEmpty ? "Add" : "Add (\(selectedOrdered.count))") {
          Task { await addSelectedMembers() }
        }
        .fontWeight(.semibold)
        .disabled(selectedMembers.isEmpty || isSaving)
      }
    }
    .overlay {
      if isSaving {
        ZStack {
          Color.black.opacity(0.25).ignoresSafeArea()
          ProgressView()
            .padding(16)
            .background(palette.card)
            .cornerRadius(10)
        }
      }
    }
  }

  @ViewBuilder
  private func groupedUsersSection(users: [ContactSearchUser]) -> some View {
    var unique: [ContactSearchUser] = []
    var seen = Set<String>()
    for user in users {
      if seen.insert(user.userID).inserted {
        unique.append(user)
      }
    }
    let grouped = Dictionary(grouping: unique) { user in
      String(user.username.prefix(1)).uppercased()
    }
    let keys = grouped.keys.sorted()

    return ForEach(keys, id: \.self) { letter in
      Section(letter) {
        ForEach(grouped[letter] ?? []) { user in
          let selected = selectedMembers.contains(user)
          ContactSearchResultRow(user: user, isSaved: selected, palette: palette)
            .contentShape(Rectangle())
            .onTapGesture {
              if selected {
                selectedMembers.remove(user)
              } else {
                selectedMembers.insert(user)
              }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(palette.border)
        }
      }
    }
  }

  private func scheduleSearch(query: String) {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      searchResults = []
      isSearching = false
      hasSearched = false
      return
    }
    isSearching = true
    searchTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 350_000_000)
      if Task.isCancelled { return }
      do {
        let results = try await ContactSearchService.search(config: config, query: trimmed)
        if !Task.isCancelled {
          searchResults = results
          isSearching = false
          hasSearched = true
        }
      } catch {
        if !Task.isCancelled {
          searchResults = []
          isSearching = false
          hasSearched = true
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
        .map {
          [
            "userId": $0.userID,
            "name": $0.username,
            "role": "member",
            "profileImage": $0.profileImage ?? "",
            "avatarUri": $0.profileImage ?? "",
          ]
        }
      onAdded(addedRaw)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

/// Legacy sheet entry point — still multi-select; prefer `AddGroupMembersPickerView` push.
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
  @FocusState private var isSearchFocused: Bool

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var candidates: [ContactSearchUser] {
    searchResults.filter { !excludedUserIds.contains($0.userID) }
  }

  private var selectedOrdered: [ContactSearchUser] {
    Array(selectedMembers).sorted {
      $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // In-sheet search (not .searchable) — avoids detent jumps with keyboard.
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(palette.secondaryText)
          TextField("Search people…", text: $searchQuery)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isSearchFocused)
          if !searchQuery.isEmpty {
            Button {
              searchQuery = ""
              scheduleSearch(query: "")
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(palette.secondaryText)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(palette.card)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)

        if !selectedOrdered.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(selectedOrdered) { user in
                Button {
                  selectedMembers.remove(user)
                } label: {
                  HStack(spacing: 6) {
                    Text(user.username)
                      .font(.system(size: 13, weight: .semibold))
                      .lineLimit(1)
                    Image(systemName: "xmark")
                      .font(.system(size: 10, weight: .bold))
                  }
                  .foregroundStyle(palette.buttonText)
                  .padding(.horizontal, 10)
                  .padding(.vertical, 7)
                  .background(Capsule(style: .continuous).fill(palette.accent))
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal, 16)
          }
          .padding(.bottom, 8)
        }

        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }

        ScrollView {
          LazyVStack(spacing: 0) {
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Text(selectedOrdered.isEmpty
                ? "Search for people to add. They join as members — promote later if needed."
                : "\(selectedOrdered.count) selected. Tap Add when ready.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            } else if isSearching {
              ProgressView()
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            } else if candidates.isEmpty {
              Text("No people found.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            } else {
              ForEach(candidates) { user in
                memberRow(user: user)
                if user.userID != candidates.last?.userID {
                  Divider()
                    .padding(.leading, 76)
                }
              }
            }
          }
        }
      }
      .background(palette.background.ignoresSafeArea())
      .navigationTitle("Add Members")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
      .onChange(of: searchQuery) { _, newValue in
        scheduleSearch(query: newValue)
      }
      .onAppear {
        isSearchFocused = true
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
          Button(selectedOrdered.isEmpty ? "Add" : "Add (\(selectedOrdered.count))") {
            Task { await addSelectedMembers() }
          }
          .fontWeight(.semibold)
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
        .map {
          [
            "userId": $0.userID,
            "name": $0.username,
            "role": "member",
            "profileImage": $0.profileImage ?? "",
            "avatarUri": $0.profileImage ?? "",
          ]
        }
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
      // Glass sheet: let the frosted material (below) show through instead of a
      // flat solid fill. The inner cards keep their tint for text contrast.
      .background(Color.clear)
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
    // Frosted-glass sheet surface (replaces the old solid dark background).
    .presentationBackground(.ultraThinMaterial)
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
