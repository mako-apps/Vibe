import SwiftUI
import UIKit

enum AppAppearanceOption: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      return "System"
    case .light:
      return "Light"
    case .dark:
      return "Dark"
    }
  }

  var interfaceStyle: UIUserInterfaceStyle {
    switch self {
    case .system:
      return .unspecified
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }
}

enum AppAppearanceController {
  static let storageKey = "vibe.app.appearance"

  static var currentOption: AppAppearanceOption {
    let rawValue =
      UserDefaults.standard.string(forKey: storageKey)
      ?? AppAppearanceOption.system.rawValue
    return AppAppearanceOption(rawValue: rawValue) ?? .system
  }

  static func setOption(_ option: AppAppearanceOption) {
    UserDefaults.standard.set(option.rawValue, forKey: storageKey)
    applyStoredPreference()
  }

  static func applyStoredPreference(to window: UIWindow? = nil) {
    let style = currentOption.interfaceStyle

    if let window {
      window.overrideUserInterfaceStyle = style
    }

    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for sceneWindow in windowScene.windows {
        sceneWindow.overrideUserInterfaceStyle = style
      }
    }
  }
}

struct AppThemePalette {
  let backgroundUIColor: UIColor
  let secondaryBackgroundUIColor: UIColor
  let cardUIColor: UIColor
  let inputUIColor: UIColor
  let elevatedUIColor: UIColor
  let textUIColor: UIColor
  let secondaryTextUIColor: UIColor
  let tertiaryTextUIColor: UIColor
  let accentUIColor: UIColor
  let accentMutedUIColor: UIColor
  let buttonUIColor: UIColor
  let buttonTextUIColor: UIColor
  let bubbleMeUIColor: UIColor
  let bubbleThemUIColor: UIColor
  let borderUIColor: UIColor
  let dividerUIColor: UIColor
  let overlayUIColor: UIColor
  let successUIColor: UIColor
  let warningUIColor: UIColor
  let dangerUIColor: UIColor

  var background: Color { Color(uiColor: backgroundUIColor) }
  var secondaryBackground: Color { Color(uiColor: secondaryBackgroundUIColor) }
  var card: Color { Color(uiColor: cardUIColor) }
  var input: Color { Color(uiColor: inputUIColor) }
  var elevated: Color { Color(uiColor: elevatedUIColor) }
  var text: Color { Color(uiColor: textUIColor) }
  var secondaryText: Color { Color(uiColor: secondaryTextUIColor) }
  var tertiaryText: Color { Color(uiColor: tertiaryTextUIColor) }
  var accent: Color { Color(uiColor: accentUIColor) }
  var accentMuted: Color { Color(uiColor: accentMutedUIColor) }
  var button: Color { Color(uiColor: buttonUIColor) }
  var buttonText: Color { Color(uiColor: buttonTextUIColor) }
  var bubbleMe: Color { Color(uiColor: bubbleMeUIColor) }
  var bubbleThem: Color { Color(uiColor: bubbleThemUIColor) }
  var border: Color { Color(uiColor: borderUIColor) }
  var divider: Color { Color(uiColor: dividerUIColor) }
  var overlay: Color { Color(uiColor: overlayUIColor) }
  var success: Color { Color(uiColor: successUIColor) }
  var warning: Color { Color(uiColor: warningUIColor) }
  var danger: Color { Color(uiColor: dangerUIColor) }

  static func resolve(for colorScheme: ColorScheme) -> AppThemePalette {
    switch colorScheme {
    case .dark:
      return AppThemePalette(
        backgroundUIColor: hex(0x121212),
        secondaryBackgroundUIColor: hex(0x151515),
        cardUIColor: hex(0x242424),
        inputUIColor: hex(0x222222),
        elevatedUIColor: hex(0x252530),
        textUIColor: hex(0xE8E6F0),
        secondaryTextUIColor: hex(0x9896A8),
        tertiaryTextUIColor: hex(0x5D5B6B),
        accentUIColor: hex(0x7CB8B8),
        accentMutedUIColor: rgba(124, 184, 184, 0.6),
        buttonUIColor: hex(0x6B9E9F),
        buttonTextUIColor: hex(0xFAFBFC),
        bubbleMeUIColor: hex(0x3D6E70),
        bubbleThemUIColor: hex(0x24242C),
        borderUIColor: rgba(248, 246, 252, 0.09),
        dividerUIColor: rgba(248, 246, 252, 0.05),
        overlayUIColor: rgba(13, 13, 18, 0.88),
        successUIColor: hex(0x5ABF8F),
        warningUIColor: hex(0xC9A33D),
        dangerUIColor: hex(0xD45A5A)
      )
    case .light:
      return AppThemePalette(
        backgroundUIColor: hex(0xF5F4F1),
        secondaryBackgroundUIColor: hex(0xF5F4F1),
        cardUIColor: hex(0xFFFFFF),
        inputUIColor: hex(0xF2F2F2),
        elevatedUIColor: hex(0xFFFFFF),
        textUIColor: hex(0x1A1A1F),
        secondaryTextUIColor: hex(0x5A5A66),
        tertiaryTextUIColor: hex(0x9A9AA3),
        accentUIColor: hex(0x4A8D8E),
        accentMutedUIColor: rgba(74, 141, 142, 0.6),
        buttonUIColor: hex(0x4A8D8E),
        buttonTextUIColor: hex(0xFEFEFE),
        bubbleMeUIColor: hex(0x007A7C),
        bubbleThemUIColor: hex(0xE0F2F1),
        borderUIColor: rgba(26, 26, 31, 0.07),
        dividerUIColor: rgba(26, 26, 31, 0.035),
        overlayUIColor: rgba(250, 249, 247, 0.90),
        successUIColor: hex(0x428A6A),
        warningUIColor: hex(0xB89338),
        dangerUIColor: hex(0xC44A4A)
      )
    @unknown default:
      return resolve(for: .dark)
    }
  }

  private static func hex(_ value: UInt, alpha: CGFloat = 1.0) -> UIColor {
    UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255.0,
      green: CGFloat((value >> 8) & 0xFF) / 255.0,
      blue: CGFloat(value & 0xFF) / 255.0,
      alpha: alpha
    )
  }

  private static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat)
    -> UIColor
  {
    UIColor(
      red: red / 255.0,
      green: green / 255.0,
      blue: blue / 255.0,
      alpha: alpha
    )
  }
}

@MainActor
final class AppToastController: ObservableObject {
  static let shared = AppToastController()

  @Published private(set) var message: String?
  private var hideTask: Task<Void, Never>?

  private init() {}

  func show(_ message: String, duration: TimeInterval = 2.6) {
    hideTask?.cancel()
    self.message = message
    hideTask = Task { [weak self] in
      guard duration > 0 else { return }
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.message = nil
      }
    }
  }

  func clear() {
    hideTask?.cancel()
    hideTask = nil
    message = nil
  }
}

struct AppUserProfile: Equatable {
  let userID: String
  let username: String
  let name: String?
  let phoneNumber: String?
  let bio: String?
  let dateOfBirth: String?
  let profileImage: String?

  var displayName: String {
    name?.nilIfBlank ?? username
  }

  var subtitle: String {
    if let phoneNumber, !phoneNumber.isEmpty {
      return phoneNumber
    }
    return "@\(username)"
  }

  init?(
    userID: String,
    username: String,
    name: String? = nil,
    phoneNumber: String? = nil,
    bio: String? = nil,
    dateOfBirth: String? = nil,
    profileImage: String? = nil
  ) {
    let resolvedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolvedUserID.isEmpty, !resolvedUsername.isEmpty else { return nil }

    self.userID = resolvedUserID
    self.username = resolvedUsername
    self.name = name?.nilIfBlank
    self.phoneNumber = phoneNumber?.nilIfBlank
    self.bio = bio?.nilIfBlank
    self.dateOfBirth = dateOfBirth?.nilIfBlank
    self.profileImage = profileImage?.nilIfBlank
  }

  init?(payload: [String: Any], fallbackConfig: AppSessionConfig? = nil) {
    let fallbackUserID = fallbackConfig?.userID ?? ""
    let fallbackUsername = fallbackConfig?.username ?? fallbackConfig?.name ?? ""
    let userID = Self.normalizedString(payload["userId"] ?? payload["id"]) ?? fallbackUserID
    let username =
      Self.normalizedString(payload["username"])
      ?? Self.normalizedString(payload["name"])
      ?? fallbackUsername

    guard let profile = AppUserProfile(
      userID: userID,
      username: username,
      name: Self.normalizedString(payload["name"]) ?? fallbackConfig?.name,
      phoneNumber: Self.normalizedString(payload["phoneNumber"] ?? payload["phone"])
        ?? fallbackConfig?.phoneNumber,
      bio: Self.normalizedString(payload["bio"]) ?? fallbackConfig?.bio,
      dateOfBirth: Self.normalizedString(payload["dateOfBirth"]) ?? fallbackConfig?.dateOfBirth,
      profileImage: Self.normalizedString(payload["profileImage"] ?? payload["profile_image"])
        ?? fallbackConfig?.profileImage
    ) else {
      return nil
    }

    self = profile
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }
}

struct AppUserProfileDraft: Equatable {
  var name: String
  var username: String
  var phoneNumber: String
  var bio: String
  var dateOfBirth: String

  init(profile: AppUserProfile?) {
    self.name = profile?.name ?? ""
    self.username = profile?.username ?? AppSessionConfig.current?.username ?? ""
    self.phoneNumber = profile?.phoneNumber ?? AppSessionConfig.current?.phoneNumber ?? ""
    self.bio = profile?.bio ?? ""
    self.dateOfBirth = profile?.dateOfBirth ?? ""
  }

  var trimmedPayload: [String: Any] {
    [
      "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
      "username": username.trimmingCharacters(in: .whitespacesAndNewlines),
      "phoneNumber": phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines),
      "bio": bio.trimmingCharacters(in: .whitespacesAndNewlines),
      "dateOfBirth": dateOfBirth.trimmingCharacters(in: .whitespacesAndNewlines),
    ]
  }
}

@MainActor
final class AppProfileController: ObservableObject {
  static let shared = AppProfileController()

  @Published private(set) var profile: AppUserProfile?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?

  private var hasLoaded = false

  private init() {}

  func loadIfNeeded() async {
    if profile == nil {
      seedFromCurrentSession()
    }
    guard !hasLoaded else { return }
    await refresh()
  }

  func refresh() async {
    guard let config = AppSessionConfig.current else {
      profile = nil
      hasLoaded = false
      errorMessage = nil
      return
    }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let fetchedProfile = try await AppProfileService.fetchProfile(config: config)
      profile = fetchedProfile
      hasLoaded = true
      persistProfileToSession(fetchedProfile)
    } catch {
      errorMessage = error.localizedDescription
      if profile == nil {
        seedFromCurrentSession()
      }
    }
  }

  func update(_ draft: AppUserProfileDraft) async throws {
    guard let config = AppSessionConfig.current else {
      throw AppProfileServiceError.invalidConfiguration
    }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let updatedProfile = try await AppProfileService.updateProfile(config: config, draft: draft)
      profile = updatedProfile
      hasLoaded = true
      persistProfileToSession(updatedProfile)
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func reset() {
    profile = nil
    isLoading = false
    errorMessage = nil
    hasLoaded = false
  }

  private func seedFromCurrentSession() {
    guard let config = AppSessionConfig.current else { return }
    profile =
      AppUserProfile(
        userID: config.userID,
        username: config.username ?? config.name ?? config.userID,
        name: config.name,
        phoneNumber: config.phoneNumber,
        bio: config.bio,
        dateOfBirth: config.dateOfBirth,
        profileImage: config.profileImage
      )
  }

  private func persistProfileToSession(_ profile: AppUserProfile) {
    ChatEngineStore.shared.updateConfig([
      "username": profile.username,
      "name": profile.name,
      "phoneNumber": profile.phoneNumber,
      "bio": profile.bio,
      "dateOfBirth": profile.dateOfBirth,
      "profileImage": profile.profileImage,
    ])
  }
}

private enum AppProfileService {
  static func fetchProfile(config: AppSessionConfig) async throws -> AppUserProfile {
    guard let url = apiURL(base: config.apiBaseURLString, path: "/user/\(config.userID)") else {
      throw AppProfileServiceError.invalidConfiguration
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    applyHeaders(&request, token: config.authToken)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AppProfileServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw AppProfileServiceError.http(
        httpResponse.statusCode,
        String(data: data, encoding: .utf8) ?? ""
      )
    }

    guard
      let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        as? [String: Any],
      let profile = AppUserProfile(payload: raw, fallbackConfig: config)
    else {
      throw AppProfileServiceError.invalidResponse
    }
    return profile
  }

  static func updateProfile(config: AppSessionConfig, draft: AppUserProfileDraft) async throws
    -> AppUserProfile
  {
    guard let url = apiURL(base: config.apiBaseURLString, path: "/user/profile") else {
      throw AppProfileServiceError.invalidConfiguration
    }

    var body = draft.trimmedPayload
    body["userId"] = config.userID

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    applyHeaders(&request, token: config.authToken)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AppProfileServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw AppProfileServiceError.http(
        httpResponse.statusCode,
        String(data: data, encoding: .utf8) ?? ""
      )
    }

    guard
      let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        as? [String: Any],
      let profile = AppUserProfile(payload: raw, fallbackConfig: config)
    else {
      throw AppProfileServiceError.invalidResponse
    }
    return profile
  }

  private static func apiURL(base: String, path: String) -> URL? {
    var normalized = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    guard !normalized.isEmpty else { return nil }

    let pathBase = normalized.lowercased().hasSuffix("/api") ? normalized : "\(normalized)/api"
    return URL(string: pathBase + path)
  }

  private static func applyHeaders(_ request: inout URLRequest, token: String) {
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
  }
}

enum AppProfileServiceError: LocalizedError {
  case invalidConfiguration
  case invalidResponse
  case http(Int, String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      return "The current session is missing profile configuration."
    case .invalidResponse:
      return "The profile service returned an invalid response."
    case let .http(statusCode, body):
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Profile update failed (\(statusCode))."
        : "Profile update failed (\(statusCode)): \(trimmed)"
    }
  }
}

@MainActor
enum AppRootControllerFactory {
  static func makeInitialController() -> UIViewController {
    if AppSessionConfig.current != nil {
      return makeAuthenticatedController()
    }
    return makeWelcomeController()
  }

  static func makeAuthenticatedController() -> UIViewController {
    UIHostingController(rootView: AppRootView())
  }

  static func makeWelcomeController() -> UIViewController {
    let navigationController = UINavigationController(rootViewController: WelcomeViewController())
    navigationController.navigationBar.prefersLargeTitles = true
    return navigationController
  }

  static func showAuthenticatedRoot(animated: Bool = true) {
    replaceRoot(with: makeAuthenticatedController(), animated: animated)
  }

  static func showWelcomeRoot(animated: Bool = true) {
    replaceRoot(with: makeWelcomeController(), animated: animated)
  }

  static func signOut(animated: Bool = true) {
    AppProfileController.shared.reset()
    AppToastController.shared.clear()
    ChatEngineStore.shared.clearConfig()
    showWelcomeRoot(animated: animated)
  }

  private static func replaceRoot(with controller: UIViewController, animated: Bool) {
    guard let window = activeWindow() else { return }

    let applyRoot = {
      window.rootViewController = controller
      AppAppearanceController.applyStoredPreference(to: window)
      window.makeKeyAndVisible()
    }

    if animated {
      UIView.transition(
        with: window,
        duration: 0.25,
        options: [.transitionCrossDissolve, .allowAnimatedContent]
      ) {
        applyRoot()
      }
    } else {
      applyRoot()
    }
  }

  private static func activeWindow() -> UIWindow? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
        return keyWindow
      }
    }
    return nil
  }
}

private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
