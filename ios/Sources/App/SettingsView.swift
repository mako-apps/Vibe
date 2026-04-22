import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct SettingsView: View {
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject private var coordinator: AppShellCoordinator
  @StateObject private var profileController = AppProfileController.shared
  @AppStorage("vibe.settings.notificationsEnabled") private var notificationsEnabled = true

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var currentProfile: AppUserProfile? {
    profileController.profile
      ?? AppUserProfile(
        userID: AppSessionConfig.current?.userID ?? "",
        username: AppSessionConfig.current?.username ?? AppSessionConfig.current?.userID ?? "You",
        name: AppSessionConfig.current?.name,
        phoneNumber: AppSessionConfig.current?.phoneNumber,
        bio: AppSessionConfig.current?.bio,
        dateOfBirth: AppSessionConfig.current?.dateOfBirth,
        profileImage: AppSessionConfig.current?.profileImage
      )
  }

  var body: some View {
    List {
      Section {
        SettingsProfileHero(profile: currentProfile, palette: palette)
          .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 12, trailing: 0))
          .listRowBackground(Color.clear)
      }

      settingsSection("ACCOUNT") {
        NavigationLink {
          ProfileSettingsDetailView(profileController: profileController)
        } label: {
          SettingsMenuRow(
            icon: "person.fill",
            title: "Edit Profile",
            tint: Color.blue
          )
        }

        Button {
          openSavedMessages()
        } label: {
          SettingsMenuRow(
            icon: "bookmark.fill",
            title: "Saved Messages",
            tint: Color.orange
          )
        }
        .buttonStyle(.plain)

        NavigationLink {
          UserQRSettingsDetailView(profile: currentProfile)
        } label: {
          SettingsMenuRow(
            icon: "qrcode",
            title: "Your QR",
            tint: Color.green,
            trailingText: "Show"
          )
        }

        NavigationLink {
          ConnectionManagerDetailView()
        } label: {
          SettingsMenuRow(
            icon: "server.rack",
            title: "Connection Manager",
            tint: Color.blue,
            trailingText: "Automatic",
            showsDivider: false
          )
        }
      }

      settingsSection("PRIVACY & SECURITY") {
        NavigationLink {
          PrivacySettingsDetailView()
        } label: {
          SettingsMenuRow(
            icon: "shield.fill",
            title: "Privacy",
            tint: Color.green,
            trailingText: "Manage"
          )
        }

        NavigationLink {
          SecretKeySettingsDetailView()
        } label: {
          SettingsMenuRow(
            icon: "key.fill",
            title: "Secret Key",
            tint: Color.purple,
            showsDivider: false
          )
        }
      }

      settingsSection("NOTIFICATIONS") {
        Toggle(isOn: $notificationsEnabled) {
          SettingsMenuRow(
            icon: "bell.fill",
            title: "Push Notifications",
            tint: Color.red,
            kind: .toggle,
            showsDivider: false
          )
        }
        .tint(palette.accent)
      }

      settingsSection("APPEARANCE") {
        NavigationLink {
          AppearanceSettingsDetailView()
        } label: {
          SettingsMenuRow(
            icon: "moon.fill",
            title: "Appearance",
            tint: Color.indigo,
            trailingText: appearanceValue,
            showsDivider: false
          )
        }
      }

      settingsSection("MEDIA & STORAGE") {
        NavigationLink {
          MediaCacheSettingsDetailView()
        } label: {
          SettingsMenuRow(
            icon: "internaldrive.fill",
            title: "Media Cache",
            tint: Color.pink,
            trailingText: "Manage",
            showsDivider: false
          )
        }
      }

      Section {
        Button(role: .destructive) {
          AppRootControllerFactory.signOut()
        } label: {
          HStack(spacing: 14) {
            SettingsRowIcon(icon: "rectangle.portrait.and.arrow.right", tint: palette.danger)
            Text("Sign Out")
              .font(.system(size: 17, weight: .medium))
              .foregroundStyle(palette.danger)
          }
          .padding(.vertical, 4)
        }
      }
      .listRowBackground(palette.card)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await profileController.loadIfNeeded()
    }
  }

  private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    Section {
      content()
        .listRowBackground(palette.card)
    } header: {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(palette.secondaryText)
    }
  }

  private var appearanceValue: String {
    let raw =
      UserDefaults.standard.string(forKey: AppAppearanceController.storageKey)
      ?? AppAppearanceOption.system.rawValue
    return (AppAppearanceOption(rawValue: raw) ?? .system).title
  }

  private func openSavedMessages() {
    let userID = AppSessionConfig.current?.userID
    coordinator.openChat(
      ChatRoute(
        chatId: "saved_messages",
        title: "Saved Messages",
        peerUserId: userID,
        avatarURI: nil,
        isGroup: false,
        initialRows: []
      )
    )
  }
}

private struct SettingsProfileHero: View {
  let profile: AppUserProfile?
  let palette: AppThemePalette

  var body: some View {
    VStack(spacing: 16) {
      avatar
        .frame(width: 88, height: 88)
        .clipShape(Circle())
        .overlay(
          Circle()
            .stroke(palette.border, lineWidth: 1)
        )

      VStack(spacing: 6) {
        Text(profile?.displayName ?? "Your Profile")
          .font(.system(size: 24, weight: .bold))
          .foregroundStyle(palette.text)

        Text(profile?.subtitle ?? "Profile details load from your current session.")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(palette.secondaryText)
          .lineLimit(2)
      }

      HStack(spacing: 12) {
        NavigationLink {
          ProfileSettingsDetailView(profileController: AppProfileController.shared)
        } label: {
          SettingsHeroButton(title: "Edit", icon: "square.and.pencil", palette: palette)
        }

        NavigationLink {
          UserQRSettingsDetailView(profile: profile)
        } label: {
          SettingsHeroButton(title: "QR", icon: "qrcode", palette: palette)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 18)
    .padding(.horizontal, 20)
    .background(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(palette.card)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(palette.border, lineWidth: 1)
    )
  }

  @ViewBuilder
  private var avatar: some View {
    if let imageURL = profile?.profileImage, let url = URL(string: imageURL) {
      AsyncImage(url: url) { phase in
        switch phase {
        case let .success(image):
          image
            .resizable()
            .scaledToFill()
        default:
          fallbackAvatar
        }
      }
    } else {
      fallbackAvatar
    }
  }

  private var fallbackAvatar: some View {
    Circle()
      .fill(
        LinearGradient(
          colors: [palette.accent.opacity(0.95), palette.button.opacity(0.85)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .overlay(
        Text(initials)
          .font(.system(size: 28, weight: .bold))
          .foregroundStyle(palette.buttonText)
      )
  }

  private var initials: String {
    let source = profile?.displayName ?? profile?.username ?? "U"
    let pieces = source.split(separator: " ")
    if pieces.count >= 2 {
      return String(pieces.prefix(2).compactMap { $0.first }).uppercased()
    }
    return String(source.prefix(1)).uppercased()
  }
}

private struct SettingsHeroButton: View {
  let title: String
  let icon: String
  let palette: AppThemePalette

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
      Text(title)
    }
    .font(.system(size: 15, weight: .semibold))
    .foregroundStyle(palette.text)
    .frame(maxWidth: .infinity)
    .frame(height: 42)
    .background(
      RoundedRectangle(cornerRadius: 21, style: .continuous)
        .fill(palette.secondaryBackground)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 21, style: .continuous)
        .stroke(palette.border, lineWidth: 1)
    )
  }
}

private enum SettingsRowKind {
  case navigation
  case toggle
}

private struct SettingsMenuRow: View {
  let icon: String
  let title: String
  let tint: Color
  var trailingText: String? = nil
  var kind: SettingsRowKind = .navigation
  var showsDivider = true

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        SettingsRowIcon(icon: icon, tint: tint)

        Text(title)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(.primary)

        Spacer(minLength: 12)

        if let trailingText, !trailingText.isEmpty {
          Text(trailingText)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
        }

        if kind == .navigation {
          Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .opacity(0.7)
        }
      }
      .padding(.vertical, 10)

      if showsDivider {
        Divider()
          .padding(.leading, 54)
      }
    }
  }
}

private struct SettingsRowIcon: View {
  let icon: String
  let tint: Color

  var body: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(tint.opacity(0.14))
      .frame(width: 30, height: 30)
      .overlay(
        Image(systemName: icon)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(tint)
      )
  }
}

private struct ProfileSettingsDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var profileController: AppProfileController

  @State private var draft = AppUserProfileDraft(profile: nil)
  @State private var saveError: String?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var baselineDraft: AppUserProfileDraft {
    AppUserProfileDraft(profile: profileController.profile)
  }

  private var isDirty: Bool {
    draft != baselineDraft
  }

  var body: some View {
    List {
      Section("Profile") {
        TextField("Name", text: $draft.name)
        TextField("Username", text: $draft.username)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Phone Number", text: $draft.phoneNumber)
          .keyboardType(.phonePad)
      }
      .listRowBackground(palette.card)

      Section("About") {
        TextField("Bio", text: $draft.bio, axis: .vertical)
          .lineLimit(3...6)
        TextField("Date of Birth", text: $draft.dateOfBirth)
      }
      .listRowBackground(palette.card)

      if let saveError {
        Section {
          Text(saveError)
            .font(.footnote)
            .foregroundStyle(palette.danger)
        }
        .listRowBackground(palette.card)
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Profile")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(profileController.isLoading ? "Saving..." : "Save") {
          Task {
            await saveProfile()
          }
        }
        .disabled(!isDirty || profileController.isLoading || draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .onAppear {
      draft = baselineDraft
    }
  }

  @MainActor
  private func saveProfile() async {
    saveError = nil
    do {
      try await profileController.update(draft)
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
  }
}

private struct UserQRSettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  let profile: AppUserProfile?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var qrValue: String {
    profile?.userID ?? AppSessionConfig.current?.userID ?? ""
  }

  var body: some View {
    List {
      Section {
        VStack(spacing: 20) {
          QRCodePanel(value: qrValue, palette: palette)
            .frame(maxWidth: .infinity)

          Text(profile?.displayName ?? "Your Profile")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(palette.text)

          Text(qrValue.isEmpty ? "No profile QR is available on this device." : qrValue)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(qrValue.isEmpty ? palette.secondaryText : palette.text)
            .textSelection(.enabled)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
      }
      .listRowBackground(palette.card)

      Section {
        Button("Copy ID") {
          UIPasteboard.general.string = qrValue
        }
        .disabled(qrValue.isEmpty)
      }
      .listRowBackground(palette.card)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Your QR")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct SecretKeySettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  @State private var isRevealed = false
  @State private var copied = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var secretKey: String {
    SecureKeyStore.shared.retrieveSecret(key: "loginSecret") ?? ""
  }

  var body: some View {
    List {
      Section {
        VStack(spacing: 18) {
          QRCodePanel(value: secretKey, palette: palette)
            .frame(maxWidth: .infinity)

          VStack(alignment: .leading, spacing: 12) {
            Text("YOUR SECRET KEY")
              .font(.system(size: 11, weight: .bold))
              .tracking(1.2)
              .foregroundStyle(palette.secondaryText)

            Text(secretKey.isEmpty ? "No secret key is stored on this device yet." : displayedSecret)
              .font(.system(.body, design: .monospaced))
              .foregroundStyle(secretKey.isEmpty ? palette.secondaryText : palette.text)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          HStack(spacing: 12) {
            Button(secretKey.isEmpty ? "Unavailable" : (isRevealed ? "Hide" : "Show")) {
              guard !secretKey.isEmpty else { return }
              isRevealed.toggle()
              copied = false
            }
            .buttonStyle(.bordered)
            .tint(palette.text)
            .disabled(secretKey.isEmpty)

            Button(copied ? "Copied" : "Copy") {
              guard !secretKey.isEmpty else { return }
              UIPasteboard.general.string = secretKey
              copied = true
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .disabled(secretKey.isEmpty)
          }
        }
        .padding(.vertical, 12)
      }
      .listRowBackground(palette.card)

      Section {
        Text("Do not share this key. Anyone with it can sign in as you on another device.")
          .font(.footnote)
          .foregroundStyle(palette.danger)
      }
      .listRowBackground(palette.card)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Secret Key")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var displayedSecret: String {
    guard !isRevealed else { return secretKey }
    let characters = Array(secretKey)
    guard !characters.isEmpty else { return "" }
    return String(
      characters.enumerated().map { index, character in
        index < 6 || index >= max(0, characters.count - 4) ? character : "•"
      }
    )
  }
}

private struct AppearanceSettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage(AppAppearanceController.storageKey) private var appearanceRaw =
    AppAppearanceOption.system.rawValue

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var selectedAppearance: Binding<AppAppearanceOption> {
    Binding(
      get: { AppAppearanceOption(rawValue: appearanceRaw) ?? .system },
      set: { nextValue in
        appearanceRaw = nextValue.rawValue
        AppAppearanceController.setOption(nextValue)
      }
    )
  }

  var body: some View {
    List {
      Section("Theme") {
        Picker("Mode", selection: selectedAppearance) {
          ForEach(AppAppearanceOption.allCases) { option in
            Text(option.title).tag(option)
          }
        }
        .pickerStyle(.inline)
      }
      .listRowBackground(palette.card)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Appearance")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct MediaCacheSettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage("vibe.settings.media.maxCacheSize") private var maxCacheSize = 100
  @AppStorage("vibe.settings.media.cacheExpiryDays") private var cacheExpiryDays = 7
  @AppStorage("vibe.settings.media.autoPlayNext") private var autoPlayNext = true
  @AppStorage("vibe.settings.media.streamQuality") private var streamQuality = "high"

  @State private var stats = AppMediaCacheController.cacheStats()

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    List {
      Section("Storage") {
        SettingsValueLine(title: "Cached tracks", value: "\(stats.trackCount)")
        SettingsValueLine(title: "Recent plays", value: "\(stats.recentlyPlayedCount)")
        SettingsValueLine(title: "Used storage", value: formattedBytes(stats.bytesUsed))
      }
      .listRowBackground(palette.card)

      Section("Playback") {
        Stepper(value: $maxCacheSize, in: 50...500, step: 25) {
          LabeledContent("Max cache size") {
            Text("\(maxCacheSize) GB")
              .foregroundStyle(.secondary)
          }
        }

        Stepper(value: $cacheExpiryDays, in: 1...60) {
          LabeledContent("Expiry window") {
            Text("\(cacheExpiryDays) days")
              .foregroundStyle(.secondary)
          }
        }

        Toggle("Auto-play next", isOn: $autoPlayNext)

        Picker("Stream quality", selection: $streamQuality) {
          Text("Low").tag("low")
          Text("Medium").tag("medium")
          Text("High").tag("high")
        }
      }
      .listRowBackground(palette.card)

      Section("Actions") {
        Button("Clear Expired") {
          AppMediaCacheController.clearExpired(olderThanDays: cacheExpiryDays)
          refreshStats()
        }

        Button("Clear All", role: .destructive) {
          AppMediaCacheController.clearAll()
          refreshStats()
        }
      }
      .listRowBackground(palette.card)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Media Cache")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      refreshStats()
    }
  }

  private func refreshStats() {
    stats = AppMediaCacheController.cacheStats()
  }

  private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

private struct ConnectionManagerDetailView: View {
  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var config: AppSessionConfig? {
    AppSessionConfig.current
  }

  var body: some View {
    List {
      Section("Connection") {
        SettingsValueLine(title: "API Base", value: config?.apiBaseURLString ?? "Unavailable")
        SettingsValueLine(title: "Socket", value: config?.socketURLString ?? "Unavailable")
        SettingsValueLine(
          title: "Transport",
          value: (config?.transportMode.rawValue ?? "unknown")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        )
        SettingsValueLine(
          title: "Bootstrap",
          value: config?.bootstrapURL?.absoluteString ?? "Unavailable"
        )
      }
      .listRowBackground(palette.card)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Connection Manager")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct PrivacySettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    List {
      Section("Privacy") {
        SettingsValueLine(title: "Phone Number", value: "Server managed")
        SettingsValueLine(title: "Last Seen & Online", value: "Server managed")
        SettingsValueLine(title: "Profile Photos", value: "Server managed")
        SettingsValueLine(title: "Bio", value: "Server managed")
        SettingsValueLine(title: "Calls", value: "Server managed")
      }
      .listRowBackground(palette.card)

      Section {
        Text("These controls match the old settings structure. Native editing of each privacy rule can be wired into the server profile endpoint next.")
          .font(.footnote)
          .foregroundStyle(palette.secondaryText)
      }
      .listRowBackground(palette.card)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Privacy")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct QRCodePanel: View {
  let value: String
  let palette: AppThemePalette

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(Color.white)
        .frame(width: 236, height: 236)

      if value.isEmpty {
        Image(systemName: "qrcode")
          .font(.system(size: 72, weight: .light))
          .foregroundStyle(palette.secondaryText)
      } else if let image = QRCodeRenderer.image(for: value) {
        Image(uiImage: image)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 200, height: 200)
      }
    }
    .shadow(color: Color.black.opacity(0.08), radius: 18, y: 8)
  }
}

private enum QRCodeRenderer {
  static let context = CIContext()

  static func image(for value: String) -> UIImage? {
    guard !value.isEmpty else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "M"
    guard let outputImage = filter.outputImage else { return nil }
    let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
      return nil
    }
    return UIImage(cgImage: cgImage)
  }
}

private struct SettingsValueLine: View {
  let title: String
  let value: String

  var body: some View {
    LabeledContent(title) {
      Text(value)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }
}

private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private struct AppMediaCacheStats {
  let trackCount: Int
  let recentlyPlayedCount: Int
  let bytesUsed: Int64
}

private enum AppMediaCacheController {
  private static let directoryNames = [
    "native-music-player-cache",
    "music_cache",
  ]

  static func cacheStats() -> AppMediaCacheStats {
    var trackCount = 0
    var bytesUsed: Int64 = 0

    for fileURL in cachedFileURLs() {
      trackCount += 1
      let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      bytesUsed += Int64(fileSize)
    }

    return AppMediaCacheStats(
      trackCount: trackCount,
      recentlyPlayedCount: 0,
      bytesUsed: bytesUsed
    )
  }

  static func clearExpired(olderThanDays days: Int) {
    let threshold = Date().addingTimeInterval(-Double(max(days, 1)) * 86_400.0)
    for fileURL in cachedFileURLs() {
      let contentDate =
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      if contentDate < threshold {
        try? FileManager.default.removeItem(at: fileURL)
      }
    }
  }

  static func clearAll() {
    for fileURL in cachedFileURLs() {
      try? FileManager.default.removeItem(at: fileURL)
    }
  }

  private static func cachedFileURLs() -> [URL] {
    let baseDirectory =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    return directoryNames.flatMap { directoryName in
      let directoryURL = baseDirectory.appendingPathComponent(directoryName, isDirectory: true)
      let fileURLs =
        (try? FileManager.default.contentsOfDirectory(
          at: directoryURL,
          includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
          options: [.skipsHiddenFiles]
        )) ?? []
      return fileURLs.filter { !$0.hasDirectoryPath }
    }
  }
}
