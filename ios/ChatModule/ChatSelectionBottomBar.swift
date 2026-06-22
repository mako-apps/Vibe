import SwiftUI

public struct ChatSelectionBottomBar: View {
  var isDark: Bool
  var peerName: String
  var onDeleteForEveryone: () -> Void
  var onDeleteForMe: () -> Void
  var onShareOutside: () -> Void
  var onShareInside: () -> Void

  public var body: some View {
    HStack(alignment: .center) {
      // Left: Delete
      Menu {
        Button(role: .destructive, action: onDeleteForEveryone) {
          Text("Delete for me and \(peerName)")
        }
        Button(role: .destructive, action: onDeleteForMe) {
          Text("Delete for me")
        }
      } label: {
        Image(systemName: "trash")
          .font(.system(size: 20, weight: .medium))
          .foregroundColor(isDark ? .white : .black)
          .frame(width: 44, height: 44)
          .background(
            VisualEffectBlur(blurStyle: isDark ? .systemThinMaterialDark : .systemThinMaterialLight)
              .clipShape(Circle())
          )
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      // Center: Share Outside
      Button(action: onShareOutside) {
        Image(systemName: "square.and.arrow.up")
          .font(.system(size: 20, weight: .medium))
          .foregroundColor(isDark ? .white : .black)
          .frame(width: 44, height: 44)
          .background(
            VisualEffectBlur(blurStyle: isDark ? .systemThinMaterialDark : .systemThinMaterialLight)
              .clipShape(Circle())
          )
      }
      .frame(maxWidth: .infinity, alignment: .center)

      // Right: Share Inside
      Button(action: onShareInside) {
        Image(systemName: "arrowshape.turn.up.right")
          .font(.system(size: 20, weight: .medium))
          .foregroundColor(isDark ? .white : .black)
          .frame(width: 44, height: 44)
          .background(
            VisualEffectBlur(blurStyle: isDark ? .systemThinMaterialDark : .systemThinMaterialLight)
              .clipShape(Circle())
          )
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 24)
    // Removed bottom padding to rely on container
    .background(Color.clear)
  }
}

struct VisualEffectBlur: UIViewRepresentable {
  var blurStyle: UIBlurEffect.Style
  
  func makeUIView(context: Context) -> UIVisualEffectView {
    return UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
  }
  
  func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
    uiView.effect = UIBlurEffect(style: blurStyle)
  }
}
