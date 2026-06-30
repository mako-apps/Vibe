import SwiftUI

struct VibeAgentDiffSheetView: View {
  let patch: String
  let fileName: String? // If nil, we show all files
  @Environment(\.dismiss) private var dismiss

  // Parsed chunks
  private struct DiffLine: Identifiable {
    let id = UUID()
    let text: String
    let type: LineType
    let oldLineNumber: Int?
    let newLineNumber: Int?

    enum LineType {
      case addition
      case deletion
      case context
      case header
    }
  }

  private var lines: [DiffLine] {
    var result: [DiffLine] = []
    let rawLines = patch.components(separatedBy: .newlines)
    
    var currentOldLine = 0
    var currentNewLine = 0
    
    for rawLine in rawLines {
      if rawLine.hasPrefix("@@") {
        // Parse hunk header: @@ -oldStart,oldCount +newStart,newCount @@
        result.append(DiffLine(text: rawLine, type: .header, oldLineNumber: nil, newLineNumber: nil))
        if let match = rawLine.range(of: #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#, options: .regularExpression) {
          let substring = rawLine[match]
          let scanner = Scanner(string: String(substring))
          _ = scanner.scanString("@@ -")
          if let oldStart = scanner.scanInt() {
            currentOldLine = oldStart
          }
          _ = scanner.scanUpToString("+")
          _ = scanner.scanString("+")
          if let newStart = scanner.scanInt() {
            currentNewLine = newStart
          }
        }
      } else if rawLine.hasPrefix("+") && !rawLine.hasPrefix("+++") {
        result.append(DiffLine(text: rawLine, type: .addition, oldLineNumber: nil, newLineNumber: currentNewLine))
        currentNewLine += 1
      } else if rawLine.hasPrefix("-") && !rawLine.hasPrefix("---") {
        result.append(DiffLine(text: rawLine, type: .deletion, oldLineNumber: currentOldLine, newLineNumber: nil))
        currentOldLine += 1
      } else if rawLine.hasPrefix(" ") || rawLine.isEmpty {
        result.append(DiffLine(text: rawLine.isEmpty ? " " : String(rawLine.dropFirst()), type: .context, oldLineNumber: currentOldLine, newLineNumber: currentNewLine))
        currentOldLine += 1
        currentNewLine += 1
      } else {
        // Headers like diff --git, +++, ---, index
        result.append(DiffLine(text: rawLine, type: .header, oldLineNumber: nil, newLineNumber: nil))
      }
    }
    return result
  }

  var body: some View {
    NavigationView {
      ScrollView {
        ScrollView(.horizontal, showsIndicators: false) {
          LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
            ForEach(lines) { line in
              HStack(alignment: .top, spacing: 0) {
                // Line numbers
                if line.type != .header {
                  Text(line.oldLineNumber.map { "\($0)" } ?? " ")
                    .frame(width: 35, alignment: .trailing)
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.trailing, 8)
                  
                  Text(line.newLineNumber.map { "\($0)" } ?? " ")
                    .frame(width: 35, alignment: .trailing)
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.trailing, 12)
                } else {
                  // For headers, leave empty space for line numbers
                  Color.clear.frame(width: 35 + 8 + 35 + 12)
                }
                
                // Text
                Text(line.type == .header ? line.text : String(line.text.prefix(1) == "+" || line.text.prefix(1) == "-" ? line.text.dropFirst() : line.text[...]))
                  .padding(.vertical, 1)
                  .padding(.horizontal, line.type == .header ? 12 : 4)
                  // Use a fixed width or just let it expand horizontally
              }
              .font(.system(size: 12.5, weight: .regular, design: .monospaced))
              .background(backgroundColor(for: line.type))
              .foregroundColor(textColor(for: line.type))
            }
          }
          .padding(.vertical, 8)
        }
      }
      .background(Color(red: 0.05, green: 0.05, blue: 0.05)) // Very dark background
      .navigationTitle(fileName ?? "Review Changes")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Close") {
            dismiss()
          }
        }
      }
      // Force dark mode for diffs to match the design
      .environment(\.colorScheme, .dark)
    }
  }

  private func backgroundColor(for type: DiffLine.LineType) -> Color {
    switch type {
    case .addition: return Color(red: 0.1, green: 0.23, blue: 0.13) // Dark green
    case .deletion: return Color(red: 0.25, green: 0.1, blue: 0.12) // Dark red
    case .context: return .clear
    case .header: return Color(red: 0.15, green: 0.15, blue: 0.15)
    }
  }

  private func textColor(for type: DiffLine.LineType) -> Color {
    switch type {
    case .addition: return Color(red: 0.5, green: 0.9, blue: 0.5) // Light green text
    case .deletion: return Color(red: 0.9, green: 0.5, blue: 0.5) // Light red text
    case .context: return .white.opacity(0.85)
    case .header: return .white.opacity(0.5)
    }
  }
}
