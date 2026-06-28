import Foundation

let path = "/Users/mohammadshayani/Vibe/ios/ChatModule/ChatListViewAppearance.swift"
var content = try! String(contentsOfFile: path)

let search1 = """
struct ChatListAppearance {
  let backgroundMode: String
"""
let replace1 = """
struct ChatListAppearance {
  let isDark: Bool
  let backgroundMode: String
"""

let search2 = """
  static let fallback = ChatListAppearance(
    backgroundMode: "transparent",
"""
let replace2 = """
  static let fallback = ChatListAppearance(
    isDark: true,
    backgroundMode: "transparent",
"""

let search3 = """
  return ChatListAppearance(
    backgroundMode: mode,
"""
let replace3 = """
  return ChatListAppearance(
    isDark: isDark,
    backgroundMode: mode,
"""

content = content.replacingOccurrences(of: search1, with: replace1)
content = content.replacingOccurrences(of: search2, with: replace2)
content = content.replacingOccurrences(of: search3, with: replace3)

try! content.write(toFile: path, atomically: true, encoding: .utf8)
