import SwiftUI
import UIKit

struct UIGlassEffectRepresentable: UIViewRepresentable {
  func makeUIView(context: Context) -> UIVisualEffectView {
    let view = UIVisualEffectView(effect: UIGlassEffect())
    return view
  }

  func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}
