import Foundation

let path = "/Users/mohammadshayani/Vibe/ios/ChatModule/ChatListView.swift"
var content = try! String(contentsOfFile: path)

// Replace usages of inputBar to handle agentComposerView conditionally
// This is complex, so I'll just write a script to patch it.

// Let's first add agentComposerView layout logic
let layoutLogic = """
    if enabled {
      if abs(contentPaddingBottom - sectionBottomInset) > 0.5 {
        contentPaddingBottom = sectionBottomInset
        updateBottomAnchorInset()
      }
      let isAgent = agentChatMode || currentBridgeProvider != nil
      if isAgent {
        let bar = VibeComposerView()
        bar.placeholder = inputBarPlaceholder
        bar.applyAppearance(appearance)
        bar.provider = currentBridgeProvider ?? "codex"
        
        bar.onSend = { [weak self] text, options in
            self?.inputBarDidSend(text: text) // Map to existing delegate
        }
        bar.onAttach = { [weak self] in
            self?.inputBarDidTapAttachment()
        }
        bar.onHeightChanged = { [weak self] height in
            self?.inputBarHeightDidChange()
        }
        
        agentComposerView = bar
        addSubview(bar)
        
        // Disable regular inputBar
        inputBar?.removeFromSuperview()
        inputBar = nil
      } else {
        let bar = ChatInputBar()
        bar.delegate = self
        bar.placeholder = inputBarPlaceholder
        bar.applyAppearance(appearance)
        bar.setAgentStreaming(agentStreaming)
        bar.setAgentControlMode(false)
        inputBar = bar
        addSubview(bar)
        
        agentComposerView?.removeFromSuperview()
        agentComposerView = nil
      }
      
      updateAgentBridgeControlTitle()
"""

if let range = content.range(of: """
    if enabled {
      if abs(contentPaddingBottom - sectionBottomInset) > 0.5 {
        contentPaddingBottom = sectionBottomInset
        updateBottomAnchorInset()
      }
      let bar = ChatInputBar()
      bar.delegate = self
      bar.placeholder = inputBarPlaceholder
      bar.applyAppearance(appearance)
      bar.setAgentStreaming(agentStreaming)
      bar.setAgentControlMode(agentChatMode || currentBridgeProvider != nil)
      inputBar = bar
      updateAgentBridgeControlTitle()

      addSubview(bar)
""") {
    content.replaceSubrange(range, with: layoutLogic)
    print("Replaced layout logic")
}

try! content.write(toFile: path, atomically: true, encoding: .utf8)
