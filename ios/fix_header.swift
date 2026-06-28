import Foundation

let path = "/Users/mohammadshayani/Vibe/ios/ChatModule/ChatMainView.swift"
var content = try! String(contentsOfFile: path)

let searchHeaderTexts = """
    chatTitleLabel.text = resolvedTitle
"""

let replaceHeaderTexts = """
    if !bridgeProvider.isEmpty {
      let attachment = NSTextAttachment()
      let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
      attachment.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: config)?.withTintColor(chatTitleLabel.textColor, renderingMode: .alwaysOriginal)
      attachment.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
      
      let attributedTitle = NSMutableAttributedString(string: "\\(resolvedTitle) ")
      attributedTitle.append(NSAttributedString(attachment: attachment))
      chatTitleLabel.attributedText = attributedTitle
    } else {
      chatTitleLabel.text = resolvedTitle
    }
"""

if let range = content.range(of: searchHeaderTexts) {
    content.replaceSubrange(range, with: replaceHeaderTexts)
    print("Replaced updateHeaderTexts")
} else {
    print("Could not find updateHeaderTexts search string")
}

try! content.write(toFile: path, atomically: true, encoding: .utf8)
