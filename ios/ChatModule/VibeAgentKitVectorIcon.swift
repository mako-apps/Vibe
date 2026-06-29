import UIKit

enum VibeAgentKitChatVectorIcon {
  enum Kind: Equatable {
    case menu
    case compose
    case search
    case arrowRight
    case document
    case thumbUp
    case thumbDown
    case refresh
    case google
    case web
    case platform
    case message
    case email
    case phone
    case travel
    case hotel
    case shopping
    case task
    case sparkles
    case profile
    case send
    case claudeAgent
    case gptAgent
  }

  private enum RenderingStyle {
    case stroke(width: CGFloat, cap: CGLineCap = .round, join: CGLineJoin = .round)
    case fill
  }

  private struct Element {
    let path: String
    let style: RenderingStyle
    var color: UIColor? = nil
    var transform: CGAffineTransform = .identity
  }

  private static let defaultViewBox = CGSize(width: 24.0, height: 24.0)
  private static let thumbGlyphPath =
    "M20.9752 12.1852L20.2361 12.0574L20.9752 12.1852ZM20.2696 16.265L19.5306 16.1371L20.2696 16.265ZM6.93777 20.4771L6.19056 20.5417L6.93777 20.4771ZM6.12561 11.0844L6.87282 11.0198L6.12561 11.0844ZM13.995 5.22142L14.7351 5.34269V5.34269L13.995 5.22142ZM13.3323 9.26598L14.0724 9.38725V9.38725L13.3323 9.26598ZM6.69814 9.67749L6.20855 9.10933H6.20855L6.69814 9.67749ZM8.13688 8.43769L8.62647 9.00585H8.62647L8.13688 8.43769ZM10.5181 4.78374L9.79208 4.59542L10.5181 4.78374ZM10.9938 2.94989L11.7197 3.13821V3.13821L10.9938 2.94989ZM12.6676 2.06435L12.4382 2.77841L12.4382 2.77841L12.6676 2.06435ZM12.8126 2.11093L13.042 1.39687L13.042 1.39687L12.8126 2.11093ZM9.86195 6.46262L10.5235 6.81599V6.81599L9.86195 6.46262ZM13.9047 3.24752L13.1787 3.43584V3.43584L13.9047 3.24752ZM11.6742 2.13239L11.3486 1.45675V1.45675L11.6742 2.13239ZM3.9716 21.4707L3.22439 21.5353L3.9716 21.4707ZM3 10.2342L3.74721 10.1696C3.71261 9.76945 3.36893 9.46758 2.96767 9.4849C2.5664 9.50221 2.25 9.83256 2.25 10.2342H3ZM20.2361 12.0574L19.5306 16.1371L21.0087 16.3928L21.7142 12.313L20.2361 12.0574ZM13.245 21.25H8.59635V22.75H13.245V21.25ZM7.68498 20.4125L6.87282 11.0198L5.3784 11.149L6.19056 20.5417L7.68498 20.4125ZM19.5306 16.1371C19.0238 19.0677 16.3813 21.25 13.245 21.25V22.75C17.0712 22.75 20.3708 20.081 21.0087 16.3928L19.5306 16.1371ZM13.2548 5.10015L12.5921 9.14472L14.0724 9.38725L14.7351 5.34269L13.2548 5.10015ZM7.18773 10.2456L8.62647 9.00585L7.64729 7.86954L6.20855 9.10933L7.18773 10.2456ZM11.244 4.97206L11.7197 3.13821L10.2678 2.76157L9.79208 4.59542L11.244 4.97206ZM12.4382 2.77841L12.5832 2.82498L13.042 1.39687L12.897 1.3503L12.4382 2.77841ZM10.5235 6.81599C10.8354 6.23198 11.0777 5.61339 11.244 4.97206L9.79208 4.59542C9.65573 5.12107 9.45699 5.62893 9.20042 6.10924L10.5235 6.81599ZM12.5832 2.82498C12.8896 2.92342 13.1072 3.16009 13.1787 3.43584L14.6307 3.05921C14.4252 2.26719 13.819 1.64648 13.042 1.39687L12.5832 2.82498ZM11.7197 3.13821C11.7548 3.0032 11.8523 2.87913 11.9998 2.80804L11.3486 1.45675C10.8166 1.71309 10.417 2.18627 10.2678 2.76157L11.7197 3.13821ZM11.9998 2.80804C12.1345 2.74311 12.2931 2.73181 12.4382 2.77841L12.897 1.3503C12.3873 1.18655 11.8312 1.2242 11.3486 1.45675L11.9998 2.80804ZM14.1537 10.9842H19.3348V9.4842H14.1537V10.9842ZM4.71881 21.4061L3.74721 10.1696L2.25279 10.2988L3.22439 21.5353L4.71881 21.4061ZM3.75 21.5127V10.2342H2.25V21.5127H3.75ZM3.22439 21.5353C3.2112 21.3828 3.33146 21.25 3.48671 21.25V22.75C4.21268 22.75 4.78122 22.1279 4.71881 21.4061L3.22439 21.5353ZM14.7351 5.34269C14.8596 4.58256 14.8241 3.80477 14.6307 3.0592L13.1787 3.43584C13.3197 3.97923 13.3456 4.54613 13.2548 5.10016L14.7351 5.34269ZM8.59635 21.25C8.12244 21.25 7.72601 20.887 7.68498 20.4125L6.19056 20.5417C6.29852 21.7902 7.3427 22.75 8.59635 22.75V21.25ZM8.62647 9.00585C9.30632 8.42 10.0392 7.72267 10.5235 6.81599L9.20042 6.10924C8.85404 6.75767 8.3025 7.30493 7.64729 7.86954L8.62647 9.00585ZM21.7142 12.313C21.9695 10.8365 20.8341 9.4842 19.3348 9.4842V10.9842C19.9014 10.9842 20.3332 11.4959 20.2361 12.0574L21.7142 12.313ZM3.48671 21.25C3.63292 21.25 3.75 21.3684 3.75 21.5127H2.25C2.25 22.1953 2.80289 22.75 3.48671 22.75V21.25ZM12.5921 9.14471C12.4344 10.1076 13.1766 10.9842 14.1537 10.9842V9.4842C14.1038 9.4842 14.0639 9.43901 14.0724 9.38725L12.5921 9.14471ZM6.87282 11.0198C6.8474 10.7258 6.96475 10.4378 7.18773 10.2456L6.20855 9.10933C5.62022 9.61631 5.31149 10.3753 5.3784 11.149L6.87282 11.0198Z"

  static func image(
    _ kind: Kind,
    color: UIColor,
    size: CGFloat
  ) -> UIImage? {
    render(
      elements: elements(for: kind),
      color: color,
      canvasSize: CGSize(width: size, height: size),
      viewBox: viewBox(for: kind)
    )
  }

  private static func viewBox(for kind: Kind) -> CGSize {
    switch kind {
    case .google:
      return CGSize(width: 24.0, height: 24.0)
    case .claudeAgent:
      return CGSize(width: 100.0, height: 100.0)
    case .gptAgent:
      return CGSize(width: 16.0, height: 16.0)
    default:
      return defaultViewBox
    }
  }

  private static func elements(for kind: Kind) -> [Element] {
    switch kind {
    case .menu:
      return [
        Element(path: "M4 6H20", style: .stroke(width: 1.8)),
        Element(path: "M4 12H16", style: .stroke(width: 1.8)),
        Element(path: "M4 18H10", style: .stroke(width: 1.8)),
      ]
    case .compose:
      return [
        Element(
          path: "M12.2424 20H17.5758M4.48485 16.5L15.8242 5.25607C16.5395 4.54674 17.6798 4.5061 18.4438 5.16268V5.16268C19.2877 5.8879 19.3462 7.17421 18.5716 7.97301L7.39394 19.5L4 20L4.48485 16.5Z",
          style: .stroke(width: 1.8)
        )
      ]
    case .search:
      return [
        Element(path: "M11 19C15.4183 19 19 15.4183 19 11C19 6.58172 15.4183 3 11 3C6.58172 3 3 6.58172 3 11C3 15.4183 6.58172 19 11 19Z", style: .stroke(width: 1.8)),
        Element(path: "M21 21L16.65 16.65", style: .stroke(width: 1.8))
      ]
    case .arrowRight:
      return [
        Element(path: "M5 12H19", style: .stroke(width: 1.8)),
        Element(path: "M13 5L20 12L13 19", style: .stroke(width: 1.8))
      ]
    case .document:
      return [
        Element(path: "M11.7769 10L16.6065 11.2941", style: .stroke(width: 1.5)),
        Element(path: "M11 12.8975L13.8978 13.6739", style: .stroke(width: 1.5)),
        Element(
          path: "M20.3116 12.6473C19.7074 14.9024 19.4052 16.0299 18.7203 16.7612C18.1795 17.3386 17.4796 17.7427 16.7092 17.9223C16.6129 17.9448 16.5152 17.9621 16.415 17.9744C15.4999 18.0873 14.3834 17.7881 12.3508 17.2435C10.0957 16.6392 8.96815 16.3371 8.23687 15.6522C7.65945 15.1114 7.25537 14.4115 7.07573 13.641C6.84821 12.6652 7.15033 11.5377 7.75458 9.28263L8.27222 7.35077C8.35912 7.02646 8.43977 6.72546 8.51621 6.44561C8.97128 4.77957 9.27709 3.86298 9.86351 3.23687C10.4043 2.65945 11.1042 2.25537 11.8747 2.07573C12.8504 1.84821 13.978 2.15033 16.2331 2.75458C18.4881 3.35883 19.6157 3.66095 20.347 4.34587C20.9244 4.88668 21.3285 5.58657 21.5081 6.35703C21.669 7.04708 21.565 7.81304 21.2766 9",
          style: .stroke(width: 1.5)
        ),
        Element(
          path: "M3.27222 16.647C3.87647 18.9021 4.17859 20.0296 4.86351 20.7609C5.40432 21.3383 6.10421 21.7424 6.87466 21.922C7.85044 22.1495 8.97798 21.8474 11.2331 21.2432C13.4881 20.6389 14.6157 20.3368 15.347 19.6519C15.8399 19.1902 16.2065 18.6126 16.415 17.9741M8.51621 6.44531C8.16368 6.53646 7.77741 6.63996 7.35077 6.75428C5.09569 7.35853 3.96815 7.66065 3.23687 8.34557C2.65945 8.88638 2.25537 9.58627 2.07573 10.3567C1.91482 11.0468 2.01883 11.8129 2.30728 13",
          style: .stroke(width: 1.5)
        ),
      ]
    case .thumbUp:
      return [Element(path: thumbGlyphPath, style: .fill)]
    case .thumbDown:
      return [
        Element(
          path: thumbGlyphPath,
          style: .fill,
          transform: CGAffineTransform(a: -1.0, b: 0.0, c: 0.0, d: -1.0, tx: 24.0, ty: 24.0)
        )
      ]
    case .refresh:
      return [
        Element(path: "M20 3V9H14", style: .stroke(width: 1.6)),
        Element(path: "M4 21V15H10", style: .stroke(width: 1.6)),
        Element(
          path: "M20 9C18.9051 7.24135 17.371 5.84237 15.5398 4.96701C13.7085 4.09165 11.6576 3.77784 9.6566 4.06486C7.65559 4.35188 5.79506 5.22723 4.29289 6.58579L4 6.875",
          style: .stroke(width: 1.6)
        ),
        Element(
          path: "M4 15C5.09492 16.7586 6.62904 18.1576 8.46025 19.033C10.2915 19.9084 12.3424 20.2222 14.3434 19.9351C16.3444 19.6481 18.2049 18.7728 19.7071 17.4142L20 17.125",
          style: .stroke(width: 1.6)
        ),
      ]
    case .google:
      return [
        Element(
          path: "M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z",
          style: .fill,
          color: rgb(66, 133, 244)
        ),
        Element(
          path: "M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z",
          style: .fill,
          color: rgb(52, 168, 83)
        ),
        Element(
          path: "M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z",
          style: .fill,
          color: rgb(251, 188, 5)
        ),
        Element(
          path: "M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z",
          style: .fill,
          color: rgb(234, 67, 53)
        ),
      ]
    case .web:
      return [
        Element(path: "M12 3C7.03 3 3 7.03 3 12C3 16.97 7.03 21 12 21C16.97 21 21 16.97 21 12C21 7.03 16.97 3 12 3Z", style: .stroke(width: 1.6)),
        Element(path: "M3.8 9H20.2", style: .stroke(width: 1.5)),
        Element(path: "M3.8 15H20.2", style: .stroke(width: 1.5)),
        Element(path: "M12 3C14.2 5.4 15.3 8.45 15.3 12C15.3 15.55 14.2 18.6 12 21", style: .stroke(width: 1.5)),
        Element(path: "M12 3C9.8 5.4 8.7 8.45 8.7 12C8.7 15.55 9.8 18.6 12 21", style: .stroke(width: 1.5)),
      ]
    case .platform:
      return [
        Element(path: "M7 8H17", style: .stroke(width: 1.6)),
        Element(path: "M12 8V16", style: .stroke(width: 1.6)),
        Element(path: "M5.5 5.5L8.5 5.5L8.5 8.5L5.5 8.5Z", style: .fill),
        Element(path: "M15.5 5.5L18.5 5.5L18.5 8.5L15.5 8.5Z", style: .fill),
        Element(path: "M10.5 15.5L13.5 15.5L13.5 18.5L10.5 18.5Z", style: .fill),
      ]
    case .message:
      return [
        Element(path: "M5 6H19V16H12L7 20V16H5Z", style: .stroke(width: 1.7)),
        Element(path: "M8 10H16", style: .stroke(width: 1.5)),
        Element(path: "M8 13H13", style: .stroke(width: 1.5)),
      ]
    case .email:
      return [
        Element(path: "M4 6H20V18H4Z", style: .stroke(width: 1.7)),
        Element(path: "M4.5 7L12 13L19.5 7", style: .stroke(width: 1.5)),
      ]
    case .phone:
      return [
        Element(path: "M7 4L10 9L8.2 11C9.6 13.8 11.8 16 14.8 17.6L17 15.8L21 18.8C20.5 20.2 19.5 21 18 21C10.3 21 4 14.7 4 7C4 5.6 4.8 4.5 7 4Z", style: .stroke(width: 1.6)),
      ]
    case .travel:
      return [
        Element(path: "M3 11L21 4L14 21L11 13L3 11Z", style: .stroke(width: 1.7)),
        Element(path: "M11 13L21 4", style: .stroke(width: 1.5)),
      ]
    case .hotel:
      return [
        Element(path: "M4 10V20", style: .stroke(width: 1.7)),
        Element(path: "M20 13V20", style: .stroke(width: 1.7)),
        Element(path: "M4 16H20", style: .stroke(width: 1.7)),
        Element(path: "M7 10H12V14H7Z", style: .stroke(width: 1.5)),
        Element(path: "M12 12H20V16H12Z", style: .stroke(width: 1.5)),
      ]
    case .shopping:
      return [
        Element(path: "M4 5H6L8.2 15H18.2L20 8H7", style: .stroke(width: 1.7)),
        Element(path: "M9 20H9.1", style: .stroke(width: 3.0)),
        Element(path: "M17 20H17.1", style: .stroke(width: 3.0)),
      ]
    case .task:
      return [
        Element(path: "M5 5H19V20H5Z", style: .stroke(width: 1.7)),
        Element(path: "M8 3V7", style: .stroke(width: 1.7)),
        Element(path: "M16 3V7", style: .stroke(width: 1.7)),
        Element(path: "M8 12L11 15L16 10", style: .stroke(width: 1.8)),
      ]
    case .sparkles:
      return [
        Element(path: "M12 3L13.8 8.2L19 10L13.8 11.8L12 17L10.2 11.8L5 10L10.2 8.2Z", style: .stroke(width: 1.6)),
        Element(path: "M18 15L19 17.5L21.5 18.5L19 19.5L18 22L17 19.5L14.5 18.5L17 17.5Z", style: .stroke(width: 1.4)),
      ]
    case .profile:
      return [
        Element(
          path: "M12 4C9.79 4 8 5.79 8 8C8 10.21 9.79 12 12 12C14.21 12 16 10.21 16 8C16 5.79 14.21 4 12 4Z",
          style: .stroke(width: 1.7)
        ),
        Element(
          path: "M4.5 20C4.5 16.41 7.86 13.5 12 13.5C16.14 13.5 19.5 16.41 19.5 20",
          style: .stroke(width: 1.7)
        ),
      ]
    case .send:
      return [
        Element(
          path: "M2.01 21L23 12L2.01 3L2 10L15 12L2 14V21Z",
          style: .fill
        )
      ]
    case .claudeAgent:
      return [
        Element(
          path: "m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z",
          style: .fill
        )
      ]
    case .gptAgent:
      return [
        Element(
          path: "M14.949 6.547a3.94 3.94 0 0 0-.348-3.273 4.11 4.11 0 0 0-4.4-1.934A4.1 4.1 0 0 0 8.423.2 4.15 4.15 0 0 0 6.305.086a4.1 4.1 0 0 0-1.891.948 4.04 4.04 0 0 0-1.158 1.753 4.1 4.1 0 0 0-1.563.679A4 4 0 0 0 .554 4.72a3.99 3.99 0 0 0 .502 4.731 3.94 3.94 0 0 0 .346 3.274 4.11 4.11 0 0 0 4.402 1.933c.382.425.852.764 1.377.995.526.231 1.095.35 1.67.346 1.78.002 3.358-1.132 3.901-2.804a4.1 4.1 0 0 0 1.563-.68 4 4 0 0 0 1.14-1.253 3.99 3.99 0 0 0-.506-4.716m-6.097 8.406a3.05 3.05 0 0 1-1.945-.694l.096-.054 3.23-1.838a.53.53 0 0 0 .265-.455v-4.49l1.366.778q.02.011.025.035v3.722c-.003 1.653-1.361 2.992-3.037 2.996m-6.53-2.75a2.95 2.95 0 0 1-.36-2.01l.095.057L5.29 12.09a.53.53 0 0 0 .527 0l3.949-2.246v1.555a.05.05 0 0 1-.022.041L6.473 13.3c-1.454.826-3.311.335-4.15-1.098m-.85-6.94A3.02 3.02 0 0 1 3.07 3.949v3.785a.51.51 0 0 0 .262.451l3.93 2.237-1.366.779a.05.05 0 0 1-.048 0L2.585 9.342a2.98 2.98 0 0 1-1.113-4.094zm11.216 2.571L8.747 5.576l1.362-.776a.05.05 0 0 1 .048 0l3.265 1.86a3 3 0 0 1 1.173 1.207 2.96 2.96 0 0 1-.27 3.2 3.05 3.05 0 0 1-1.36.997V8.279a.52.52 0 0 0-.276-.445m1.36-2.015-.097-.057-3.226-1.855a.53.53 0 0 0-.53 0L6.249 6.153V4.598a.04.04 0 0 1 .019-.04L9.533 2.7a3.07 3.07 0 0 1 3.257.139c.474.325.843.778 1.066 1.303.223.526.289 1.103.191 1.664zM5.503 8.575 4.139 7.8a.05.05 0 0 1-.026-.037V4.049c0-.57.166-1.127.476-1.607s.752-.864 1.275-1.105a3.08 3.08 0 0 1 3.234.41l-.096.054-3.23 1.838a.53.53 0 0 0-.265.455zm.742-1.577 1.758-1 1.762 1v2l-1.755 1-1.762-1z",
          style: .fill
        )
      ]
    }
  }

  private static func render(
    elements: [Element],
    color: UIColor,
    canvasSize: CGSize,
    viewBox: CGSize
  ) -> UIImage? {
    guard canvasSize.width > 0.0, canvasSize.height > 0.0 else {
      return nil
    }

    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
    let scale = min(canvasSize.width / viewBox.width, canvasSize.height / viewBox.height)

    return renderer.image { context in
      for element in elements {
        guard let path = SVGPathParser.makeBezierPath(from: element.path) else {
          continue
        }
        path.apply(element.transform)
        path.apply(CGAffineTransform(scaleX: scale, y: scale))

        switch element.style {
        case .fill:
          (element.color ?? color).setFill()
          path.fill()
        case .stroke(let width, let cap, let join):
          (element.color ?? color).setStroke()
          path.lineWidth = width * scale
          path.lineCapStyle = lineCapStyle(for: cap)
          path.lineJoinStyle = lineJoinStyle(for: join)
          path.stroke()
        }
      }
    }
  }

  private static func lineCapStyle(for cap: CGLineCap) -> CGLineCap {
    cap
  }

  private static func lineJoinStyle(for join: CGLineJoin) -> CGLineJoin {
    join
  }

  private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1.0) -> UIColor {
    UIColor(red: red / 255.0, green: green / 255.0, blue: blue / 255.0, alpha: alpha)
  }
}

private enum SVGPathParser {
  private enum Token {
    case command(Character)
    case number(CGFloat)
  }

  static func makeBezierPath(from string: String) -> UIBezierPath? {
    let tokens = tokenize(string)
    guard !tokens.isEmpty else {
      return nil
    }

    let path = UIBezierPath()
    var index = 0
    var command: Character = "M"
    var currentPoint = CGPoint.zero
    var subpathStart = CGPoint.zero

    func nextNumber() -> CGFloat? {
      guard index < tokens.count else {
        return nil
      }
      guard case .number(let value) = tokens[index] else {
        return nil
      }
      index += 1
      return value
    }

    func hasNumber() -> Bool {
      guard index < tokens.count else {
        return false
      }
      if case .number = tokens[index] {
        return true
      }
      return false
    }

    while index < tokens.count {
      if case .command(let nextCommand) = tokens[index] {
        command = nextCommand
        index += 1
      }

      switch command {
      case "M", "m":
        var isFirstPoint = true
        while hasNumber() {
          guard let x = nextNumber(), let y = nextNumber() else {
            return path
          }
          let point = CGPoint(
            x: command == "m" ? currentPoint.x + x : x,
            y: command == "m" ? currentPoint.y + y : y
          )
          if isFirstPoint {
            path.move(to: point)
            subpathStart = point
            isFirstPoint = false
          } else {
            path.addLine(to: point)
          }
          currentPoint = point
        }

      case "L", "l":
        while hasNumber() {
          guard let x = nextNumber(), let y = nextNumber() else {
            return path
          }
          let point = CGPoint(
            x: command == "l" ? currentPoint.x + x : x,
            y: command == "l" ? currentPoint.y + y : y
          )
          path.addLine(to: point)
          currentPoint = point
        }

      case "H", "h":
        while hasNumber() {
          guard let x = nextNumber() else {
            return path
          }
          let point = CGPoint(
            x: command == "h" ? currentPoint.x + x : x,
            y: currentPoint.y
          )
          path.addLine(to: point)
          currentPoint = point
        }

      case "V", "v":
        while hasNumber() {
          guard let y = nextNumber() else {
            return path
          }
          let point = CGPoint(
            x: currentPoint.x,
            y: command == "v" ? currentPoint.y + y : y
          )
          path.addLine(to: point)
          currentPoint = point
        }

      case "C", "c":
        while hasNumber() {
          guard
            let x1 = nextNumber(),
            let y1 = nextNumber(),
            let x2 = nextNumber(),
            let y2 = nextNumber(),
            let x = nextNumber(),
            let y = nextNumber()
          else {
            return path
          }
          let control1 = CGPoint(
            x: command == "c" ? currentPoint.x + x1 : x1,
            y: command == "c" ? currentPoint.y + y1 : y1
          )
          let control2 = CGPoint(
            x: command == "c" ? currentPoint.x + x2 : x2,
            y: command == "c" ? currentPoint.y + y2 : y2
          )
          let destination = CGPoint(
            x: command == "c" ? currentPoint.x + x : x,
            y: command == "c" ? currentPoint.y + y : y
          )
          path.addCurve(to: destination, controlPoint1: control1, controlPoint2: control2)
          currentPoint = destination
        }

      case "Q", "q":
        while hasNumber() {
          guard
            let x1 = nextNumber(), let y1 = nextNumber(),
            let x = nextNumber(), let y = nextNumber()
          else { return path }
          let control = CGPoint(
            x: command == "q" ? currentPoint.x + x1 : x1,
            y: command == "q" ? currentPoint.y + y1 : y1
          )
          let destination = CGPoint(
            x: command == "q" ? currentPoint.x + x : x,
            y: command == "q" ? currentPoint.y + y : y
          )
          path.addQuadCurve(to: destination, controlPoint: control)
          currentPoint = destination
        }

      case "A", "a":
        while hasNumber() {
          guard
            let rx = nextNumber(), let ry = nextNumber(),
            let xRotDeg = nextNumber(),
            let largeArcRaw = nextNumber(), let sweepRaw = nextNumber(),
            let ex = nextNumber(), let ey = nextNumber()
          else { return path }
          let dest = CGPoint(
            x: command == "a" ? currentPoint.x + ex : ex,
            y: command == "a" ? currentPoint.y + ey : ey
          )
          for (c1, c2, ep) in svgArcToCubic(
            from: currentPoint, to: dest,
            rx: abs(rx), ry: abs(ry),
            xAngleDeg: xRotDeg,
            largeArc: largeArcRaw != 0,
            sweep: sweepRaw != 0
          ) {
            path.addCurve(to: ep, controlPoint1: c1, controlPoint2: c2)
          }
          currentPoint = dest
        }

      case "Z", "z":
        path.close()
        currentPoint = subpathStart

      default:
        return path
      }
    }

    return path
  }

  // Converts an SVG arc to one or more cubic bezier segments (endpoint parameterization → center).
  private static func svgArcToCubic(
    from p1: CGPoint, to p2: CGPoint,
    rx: CGFloat, ry: CGFloat,
    xAngleDeg: CGFloat,
    largeArc: Bool, sweep: Bool
  ) -> [(CGPoint, CGPoint, CGPoint)] {
    guard rx > 0, ry > 0, p1 != p2 else { return [] }
    let phi = xAngleDeg * .pi / 180
    let cosPhi = cos(phi), sinPhi = sin(phi)
    let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
    let x1p = cosPhi * dx + sinPhi * dy
    let y1p = -sinPhi * dx + cosPhi * dy
    var rx = rx, ry = ry
    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }
    let rxSq = rx * rx, rySq = ry * ry
    let x1pSq = x1p * x1p, y1pSq = y1p * y1p
    var sq = (rxSq * rySq - rxSq * y1pSq - rySq * x1pSq) / (rxSq * y1pSq + rySq * x1pSq)
    sq = max(0, sq)
    let k = (largeArc == sweep ? -1.0 : 1.0) * sqrt(sq)
    let cxp = k * rx * y1p / ry
    let cyp = -k * ry * x1p / rx
    let midX = (p1.x + p2.x) / 2, midY = (p1.y + p2.y) / 2
    let cx = cosPhi * cxp - sinPhi * cyp + midX
    let cy = sinPhi * cxp + cosPhi * cyp + midY

    func vecAngle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
      let dot = ux * vx + uy * vy
      let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
      var a = acos(max(-1, min(1, dot / len)))
      if ux * vy - uy * vx < 0 { a = -a }
      return a
    }
    let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
    let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
    var theta = vecAngle(1, 0, ux, uy)
    var dtheta = vecAngle(ux, uy, vx, vy)
    if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
    if sweep && dtheta < 0 { dtheta += 2 * .pi }

    let segments = max(1, Int(ceil(abs(dtheta) / (.pi / 2))))
    let step = dtheta / CGFloat(segments)
    var result: [(CGPoint, CGPoint, CGPoint)] = []
    for i in 0..<segments {
      let t1 = theta + CGFloat(i) * step
      let t2 = t1 + step
      let alpha = 4.0 / 3.0 * tan(step / 4)
      func pt(_ t: CGFloat) -> CGPoint {
        let ct = cos(t), st = sin(t)
        return CGPoint(x: cosPhi * rx * ct - sinPhi * ry * st + cx,
                       y: sinPhi * rx * ct + cosPhi * ry * st + cy)
      }
      func dpt(_ t: CGFloat) -> CGPoint {
        let ct = cos(t), st = sin(t)
        return CGPoint(x: -cosPhi * rx * st - sinPhi * ry * ct,
                       y: -sinPhi * rx * st + cosPhi * ry * ct)
      }
      let ep = pt(t2)
      let d1 = dpt(t1), d2 = dpt(t2)
      let c1 = CGPoint(x: pt(t1).x + alpha * d1.x, y: pt(t1).y + alpha * d1.y)
      let c2 = CGPoint(x: ep.x - alpha * d2.x, y: ep.y - alpha * d2.y)
      result.append((c1, c2, ep))
    }
    return result
  }

  private static func tokenize(_ string: String) -> [Token] {
    var tokens: [Token] = []
    var index = string.startIndex

    while index < string.endIndex {
      let character = string[index]

      if character.isWhitespace || character == "," {
        index = string.index(after: index)
        continue
      }

      if character.isLetter {
        tokens.append(.command(character))
        index = string.index(after: index)
        continue
      }

      var numberEnd = index
      var hasExponent = false
      var hasDecimal = false
      while numberEnd < string.endIndex {
        let next = string[numberEnd]
        if next.isNumber {
          numberEnd = string.index(after: numberEnd)
          continue
        }
        if next == "." {
          if hasDecimal { break }
          hasDecimal = true
          numberEnd = string.index(after: numberEnd)
          continue
        }
        if next == "-" || next == "+" {
          if numberEnd == index {
            numberEnd = string.index(after: numberEnd)
            continue
          }
          let previous = string[string.index(before: numberEnd)]
          if previous == "e" || previous == "E" {
            numberEnd = string.index(after: numberEnd)
            continue
          }
          break
        }
        if (next == "e" || next == "E"), !hasExponent {
          hasExponent = true
          numberEnd = string.index(after: numberEnd)
          continue
        }
        break
      }

      guard numberEnd > index else {
        index = string.index(after: index)
        continue
      }

      let token = String(string[index..<numberEnd])
      if let value = Double(token) {
        tokens.append(.number(CGFloat(value)))
      }
      index = numberEnd
    }

    return tokens
  }
}
