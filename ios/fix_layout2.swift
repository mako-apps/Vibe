import Foundation

let path = "/Users/mohammadshayani/Vibe/ios/ChatModule/ChatListView.swift"
var content = try! String(contentsOfFile: path)

// Layout updates
let searchLayout = """
  private func layoutInputBarAndInset() {
    guard let bar = inputBar else { return }
    let w = bounds.width
"""

let replaceLayout = """
  private func layoutInputBarAndInset() {
    if let agentBar = agentComposerView {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        let distanceBeforeInsetChange = currentDistanceFromBottom()
        let wasNearBottom = distanceBeforeInsetChange <= listBottomThreshold
        
        let preferredHeight = agentBar.preferredHeight
        let effectiveKeyboardHeight = keyboardHeight
        let safeBottom = keyboardHeight > 0 ? 0 : safeAreaInsets.bottom
        
        let finalHeight = preferredHeight
        let finalY = h - effectiveKeyboardHeight - finalHeight
        
        agentBar.frame = CGRect(x: 0, y: finalY, width: w, height: finalHeight)
        
        let desiredBottomPadding = effectiveKeyboardHeight + finalHeight
        if abs(contentPaddingBottom - desiredBottomPadding) > 0.5 {
          contentPaddingBottom = desiredBottomPadding
          updateBottomAnchorInset()
          if wasNearBottom || shouldAutoScroll {
            scrollToBottom(animated: false, force: true)
          } else {
            restoreStationaryDistance(distanceBeforeInsetChange)
          }
        }
        return
    }

    guard let bar = inputBar else { return }
    let w = bounds.width
"""

if let range = content.range(of: searchLayout) {
    content.replaceSubrange(range, with: replaceLayout)
    print("Replaced layoutInputBarAndInset")
} else {
    print("Could not find search string")
}

try! content.write(toFile: path, atomically: true, encoding: .utf8)
