import Foundation

let path = "/Users/mohammadshayani/Vibe/ios/ChatModule/ChatListView.swift"
var content = try! String(contentsOfFile: path)

// Layout updates
let searchLayout = """
    if inputBarEnabled, let bar = inputBar {
      let kb = keyboardHeightForPanels
      let gap: CGFloat = kb > 0 ? 0 : 4
      bar.frame = CGRect(
        x: safeAreaInsets.left + 4,
        y: viewHeight - kb - safeAreaInsets.bottom - bar.preferredHeight - gap,
        width: viewWidth - safeAreaInsets.left - safeAreaInsets.right - 8,
        height: bar.preferredHeight
      )
    }
"""

let replaceLayout = """
    if inputBarEnabled {
      let kb = keyboardHeightForPanels
      let gap: CGFloat = kb > 0 ? 0 : 4
      if let bar = inputBar {
          bar.frame = CGRect(
            x: safeAreaInsets.left + 4,
            y: viewHeight - kb - safeAreaInsets.bottom - bar.preferredHeight - gap,
            width: viewWidth - safeAreaInsets.left - safeAreaInsets.right - 8,
            height: bar.preferredHeight
          )
      } else if let bar = agentComposerView {
          bar.frame = CGRect(
            x: 0,
            y: viewHeight - kb - bar.preferredHeight,
            width: viewWidth,
            height: bar.preferredHeight
          )
      }
    }
"""

if let range = content.range(of: searchLayout) {
    content.replaceSubrange(range, with: replaceLayout)
    print("Replaced layout")
}

try! content.write(toFile: path, atomically: true, encoding: .utf8)
