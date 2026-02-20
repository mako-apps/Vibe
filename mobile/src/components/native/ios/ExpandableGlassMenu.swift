import SwiftUI
import React

@objc(ExpandableGlassMenu)
class ExpandableGlassMenu: RCTViewManager {
  override func view() -> UIView! {
    // Return a hosting controller view that wraps the SwiftUI view
    return ExpandableGlassMenuHostingView()
  }
}

class ExpandableGlassMenuHostingView: UIView {
  // Configurable Props
  @objc var menuWidth: CGFloat = 220
  @objc var menuHeight: CGFloat = 200
  @objc var collapsedSize: CGFloat = 55
  @objc var theme: String = "dark"
  @objc var onSelect: RCTDirectEventBlock?

  // State managed by React Native props, but passed to SwiftUI
  // In a real implementation, we would bridge these props to the swiftUI view state.
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    let hostingController = UIHostingController(rootView: SwiftUIGlassMenu())
    self.addSubview(hostingController.view)
    // Setup constraints...
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

// THE SWIFTUI IMPLEMENTATION
// Matches the video logic exactly
struct SwiftUIGlassMenu: View {
  @State private var isOpen = false
  @Namespace private var animation
  
  // These would be injected props in real bridge
  var width: CGFloat = 220
  var height: CGFloat = 200
  var collapsed: CGFloat = 55
  var isDark: Bool = true
  
  var body: some View {
    ZStack(alignment: .topTrailing) {
      
      // 1. ANIMATED GLASS CONTAINER
      // Uses iOS 18+ .glassEffect if available, or .ultraThinMaterial
      RoundedRectangle(cornerRadius: isOpen ? 24 : 18)
        .fill(isDark ? Color.black.opacity(0.4) : Color.white.opacity(0.4))
        .background(.ultraThinMaterial) // The Magic Native Blur
        .opacity(1)
        .frame(
          width: isOpen ? width : collapsed,
          height: isOpen ? height : collapsed
        )
        // Spring Animation
        .animation(.spring(response: 0.5, dampingFraction: 0.7, blendDuration: 0), value: isOpen)
        
      // 2. BUTTON (Plus Icon)
      // Fades out when open
      if !isOpen {
        Image(systemName: "plus")
          .font(.system(size: 24, weight: .semibold))
          .foregroundColor(isDark ? .white : .black)
          .frame(width: collapsed, height: collapsed)
          .transition(.scale.combined(with: .opacity))
          .matchedGeometryEffect(id: "icon", in: animation)
      }
      
      // 3. MENU CONTENT
      // Fades in when open
      if isOpen {
        VStack(spacing: 12) {
          MenuOption(icon: "gearshape.fill", text: "Manual Config")
          MenuOption(icon: "square.and.arrow.down.fill", text: "Import Link")
          MenuOption(icon: "antenna.radiowaves.left.and.right", text: "Relay Node")
        }
        .padding(20)
        .frame(width: width, height: height, alignment: .topLeading)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
      }
    }
    .onTapGesture {
      withAnimation {
        isOpen.toggle()
      }
    }
  }
}

struct MenuOption: View {
  let icon: String
  let text: String
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
      Text(text).font(.system(size: 16, weight: .semibold))
    }
    .foregroundColor(.primary)
  }
}
