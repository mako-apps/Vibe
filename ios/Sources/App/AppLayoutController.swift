import SwiftUI

/// Route value for the per-tab SwiftUI navigation stacks (Contacts / Calls /
/// Settings). The chat conversation and profile are no longer SwiftUI
/// destinations — they are pushed natively onto a UIKit `UINavigationController`
/// owned by `AppRootTabBarController` — so this enum is kept only for the
/// remaining SwiftUI tab paths in `AppShellCoordinator`.
enum AppRoute: Hashable {
  case chat(PresentedChatRoute)
  case chatProfile(PresentedChatProfileRoute)
}
