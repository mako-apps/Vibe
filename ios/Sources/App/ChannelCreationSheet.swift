import SwiftUI
import PhotosUI

struct ChannelCreationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject private var coordinator: AppShellCoordinator

  let config: AppSessionConfig
  let onCreated: (ChatRoute) -> Void

  @State private var channelName = ""
  @State private var channelDescription = ""
  @State private var avatarItem: PhotosPickerItem?
  @State private var avatarImage: Image?
  @State private var avatarData: Data?
  @State private var isCreating = false
  @State private var errorMessage: String?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 20) {
        Text("Create a broadcast channel.")
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

            TextField("Channel name", text: $channelName)
              .font(.body)
              .submitLabel(.done)
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
      .background(palette.background.ignoresSafeArea())
      .navigationTitle("New Channel")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Create") {
            Task { await createChannel() }
          }
          .disabled(isCreating || channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

  @MainActor
  private func createChannel() async {
    isCreating = true
    errorMessage = nil
    defer { isCreating = false }

    do {
      var remoteAvatarUrl: String? = nil
      if let avatarData {
        remoteAvatarUrl = try await ChatRoomCreateService.uploadAvatar(imageData: avatarData, config: config)
      }

      let result = try await ChatRoomCreateService.create(
        kind: .channel,
        config: config,
        name: channelName,
        avatarUrl: remoteAvatarUrl
      )
      
      let route = ChatRoute(
        chatId: result.chatID,
        title: result.name,
        peerUserId: nil,
        avatarURI: remoteAvatarUrl,
        isGroup: false,
        initialRows: []
      )
      onCreated(route)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
