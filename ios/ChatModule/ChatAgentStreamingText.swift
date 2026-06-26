import UIKit

private let chatNativeAgentBoldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
private let chatNativeAgentMarkdownLinkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\((https?://[^)]+)\\)")
private let chatNativeAgentInlineCodeRegex = try! NSRegularExpression(pattern: "`([^`]+)`")

protocol ChatNativeStreamingTextLabelDelegate: AnyObject {
  func streamingTextLabel(_ label: ChatNativeStreamingTextLabel, didTap url: URL)
}

/// Block type emitted by ChatNativeAgentTextRenderer.parseBlocks.
enum AgentParsedBlock: Equatable {
  case text(String)
  case code(String, String?) // code + optional language
  case agentPack(AgentIntegrationPack)
  case agentRuntime(ChatListRow.AgentRuntimeSummary)
}

struct AgentIntegrationPack: Equatable {
  let agentId: String
  let displayName: String
  let username: String?
  let status: String
  let environment: String
  let eventsURL: String?
  let invokeURL: String?

  var summary: String {
    "Your \(displayName) agent is ready."
  }

  var storageKey: String {
    "agent-pack:\(agentId)"
  }
}

enum ChatNativeAgentTextRenderer {
  static func isRTL(_ text: String) -> Bool {
    text.range(of: "[\\u0600-\\u06FF]", options: .regularExpression) != nil
  }

  static func makeAttributedText(
    text: String,
    font: UIFont,
    textColor: UIColor,
    lineHeight: CGFloat? = nil
  ) -> NSAttributedString {
    let isRtl = isRTL(text)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = isRtl ? .right : .natural
    paragraphStyle.baseWritingDirection = isRtl ? .rightToLeft : .leftToRight
    paragraphStyle.lineBreakMode = .byWordWrapping
    if let lineHeight {
      paragraphStyle.minimumLineHeight = lineHeight
      paragraphStyle.maximumLineHeight = lineHeight
    }

    var baseAttrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor,
      .paragraphStyle: paragraphStyle,
    ]
    if let lineHeight {
      baseAttrs[.baselineOffset] = (lineHeight - font.lineHeight) * 0.25
    }

    return applyLineMarkdown(text, baseAttrs: baseAttrs, font: font, textColor: textColor)
  }

  // MARK: - Block parsing

  /// Split raw markdown into text, fenced-code, and structured agent-pack blocks.
  static func parseBlocks(_ text: String) -> [AgentParsedBlock] {
    if let pack = parseAgentIntegrationPack(text) {
      return [.text(pack.summary), .agentPack(pack)]
    }

    var blocks: [AgentParsedBlock] = []
    var normalLines: [String] = []
    var codeLines: [String] = []
    var inCodeBlock = false
    var currentLang: String? = nil
    for line in text.components(separatedBy: "\n") {
      if line.hasPrefix("```") {
        let fenceInfo = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if inCodeBlock {
          let code = codeLines.joined(separator: "\n")
          if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.code(code, currentLang))
          }
          codeLines = []
          currentLang = nil
          inCodeBlock = false
        } else {
          let normal = normalLines.joined(separator: "\n")
          if !normal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(normal))
          }
          normalLines = []
          inCodeBlock = true
          currentLang = fenceInfo.isEmpty ? nil : fenceInfo
        }
      } else if inCodeBlock {
        codeLines.append(line)
      } else {
        normalLines.append(line)
      }
    }
    if inCodeBlock, !codeLines.isEmpty {
      blocks.append(.code(codeLines.joined(separator: "\n"), currentLang))
    } else if !normalLines.isEmpty {
      let t = normalLines.joined(separator: "\n")
      if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.text(t)) }
    }
    return blocks.isEmpty ? [.text(text)] : blocks
  }

  private static func parseAgentIntegrationPack(_ text: String) -> AgentIntegrationPack? {
    let markerCount = [
      "Agent Details:",
      "Environment Variables:",
      "VIBE_AGENT_IDENTIFIER=",
      "API Endpoints:",
    ].filter { text.localizedCaseInsensitiveContains($0) }.count
    guard markerCount >= 2 else { return nil }

    let normalized =
      text
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "__", with: "")
    guard
      let agentId = firstCapture(
        in: normalized,
        pattern: #"(?im)^\s*[-*]?\s*Agent ID\s*:\s*`?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})`?"#
      ),
      let environment = firstCapture(
        in: normalized,
        pattern: #"(?is)Environment Variables\s*:\s*```[^\n]*\n(.*?)```"#
      )?.trimmingCharacters(in: .whitespacesAndNewlines),
      !environment.isEmpty
    else {
      return nil
    }

    let username =
      firstCapture(
        in: normalized,
        pattern: #"(?im)^\s*[-*]?\s*Username\s*:\s*`?@?([a-z0-9_]{3,64})`?"#
      )
      ?? firstCapture(
        in: normalized,
        pattern: #"(?im)^\s*VIBE_AGENT_IDENTIFIER\s*=\s*([a-z0-9_]{3,64})\s*$"#
      )
    let displayName =
      firstCapture(
        in: normalized,
        pattern: #"(?i)\bYour\s+([^\n]{1,80}?)\s+agent\s+is\s+ready\b"#
      )?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? username
      ?? "Agent"
    let eventsURL = firstCapture(
      in: normalized,
      pattern: #"(?im)^\s*[-*]?\s*Events\s*:\s*(?:\[)?(https?://[^\s\])`]+)"#
    )
    let invokeURL = firstCapture(
      in: normalized,
      pattern: #"(?im)^\s*[-*]?\s*Invoke\s*:\s*(?:\[)?(https?://[^\s\])`]+)"#
    )
    let status =
      normalized.localizedCaseInsensitiveContains("published status")
      || normalized.localizedCaseInsensitiveContains("is published")
      ? "published" : "draft"

    return AgentIntegrationPack(
      agentId: agentId,
      displayName: displayName,
      username: username,
      status: status,
      environment: environment,
      eventsURL: eventsURL,
      invokeURL: invokeURL
    )
  }

  private static func firstCapture(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
      match.numberOfRanges > 1,
      let captureRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }
    return String(text[captureRange])
  }

  // MARK: - Line-level markdown

  // MARK: - Line-level helpers

  /// Processes a normal-text block line by line, handling headings and table
  /// separator rows, then applying inline formatting to each regular line.
  private static func applyLineMarkdown(
    _ text: String,
    baseAttrs: [NSAttributedString.Key: Any],
    font: UIFont,
    textColor: UIColor
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    var addedAny = false

    for line in text.components(separatedBy: "\n") {
      // Skip table separator rows like |---|---|
      if isTableSeparatorLine(line) { continue }

      if addedAny {
        result.append(NSAttributedString(string: "\n", attributes: baseAttrs))
      }

      // Heading lines: # / ## / ###
      if let (level, headingText) = parseHeadingLine(line) {
        result.append(renderHeadingLine(headingText, level: level, baseFont: font, textColor: textColor, baseAttrs: baseAttrs))
        addedAny = true
        continue
      }

      // Regular line with inline formatting (bold, links, code, URLs).
      result.append(applyInlineFormatting(line, baseAttrs: baseAttrs, font: font))
      addedAny = true
    }

    return result
  }

  private static func isTableSeparatorLine(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.count > 2, t.hasPrefix("|") else { return false }
    for ch in t { if ch != "|" && ch != "-" && ch != ":" && ch != " " { return false } }
    return true
  }

  private static func parseHeadingLine(_ line: String) -> (Int, String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var level = 0
    var idx = trimmed.startIndex
    while idx < trimmed.endIndex, trimmed[idx] == "#" {
      level += 1
      idx = trimmed.index(after: idx)
    }
    guard level >= 1, level <= 6, idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
    let content = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
    return content.isEmpty ? nil : (level, content)
  }

  private static func renderHeadingLine(
    _ text: String,
    level: Int,
    baseFont: UIFont,
    textColor: UIColor,
    baseAttrs: [NSAttributedString.Key: Any]
  ) -> NSAttributedString {
    let scale: CGFloat = level == 1 ? 1.22 : level == 2 ? 1.10 : 1.0
    let headingFont: UIFont = {
      if let d = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
        return UIFont(descriptor: d, size: round(baseFont.pointSize * scale))
      }
      return UIFont.boldSystemFont(ofSize: round(baseFont.pointSize * scale))
    }()
    // Build a fresh paragraph style without the tight line-height lock.
    let ps = NSMutableParagraphStyle()
    if let existing = baseAttrs[.paragraphStyle] as? NSParagraphStyle { ps.setParagraphStyle(existing) }
    ps.minimumLineHeight = 0
    ps.maximumLineHeight = 0
    var attrs = baseAttrs
    attrs[.font] = headingFont
    attrs[.foregroundColor] = textColor
    attrs[.paragraphStyle] = ps
    attrs.removeValue(forKey: .baselineOffset)
    return NSAttributedString(string: text, attributes: attrs)
  }

  private static func applyInlineFormatting(
    _ text: String,
    baseAttrs: [NSAttributedString.Key: Any],
    font: UIFont
  ) -> NSAttributedString {
    let mutable = NSMutableAttributedString(string: text, attributes: baseAttrs)

    // 1) Markdown links [label](url) — replace first to preserve offsets.
    let linkMatches = chatNativeAgentMarkdownLinkRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in linkMatches.reversed() {
      guard
        let labelRange = Range(match.range(at: 1), in: mutable.string),
        let urlRange = Range(match.range(at: 2), in: mutable.string)
      else { continue }
      let label = String(mutable.string[labelRange])
      let urlString = String(mutable.string[urlRange])
      mutable.replaceCharacters(in: match.range, with: NSAttributedString(string: label, attributes: baseAttrs))
      let replacedRange = NSRange(location: match.range.location, length: (label as NSString).length)
      if let url = URL(string: urlString) {
        mutable.addAttribute(.link, value: url, range: replacedRange)
        mutable.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: replacedRange)
        mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: replacedRange)
      }
    }

    // 2) Bold **text**
    let boldMatches = chatNativeAgentBoldRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in boldMatches.reversed() {
      guard let range = Range(match.range(at: 1), in: mutable.string) else { continue }
      let boldText = String(mutable.string[range])
      var boldAttrs = baseAttrs
      if let d = font.fontDescriptor.withSymbolicTraits(.traitBold) {
        boldAttrs[.font] = UIFont(descriptor: d, size: font.pointSize)
      } else {
        boldAttrs[.font] = UIFont.boldSystemFont(ofSize: font.pointSize)
      }
      mutable.replaceCharacters(in: match.range, with: NSAttributedString(string: boldText, attributes: boldAttrs))
    }

    // 3) Inline code `code`
    let codeMatches = chatNativeAgentInlineCodeRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in codeMatches.reversed() {
      guard let range = Range(match.range(at: 1), in: mutable.string) else { continue }
      let codeText = String(mutable.string[range])
      var codeAttrs = baseAttrs
      codeAttrs[.font] = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
      mutable.replaceCharacters(in: match.range, with: NSAttributedString(string: codeText, attributes: codeAttrs))
    }

    // 4) Auto-detect bare URLs — show clean hostname+path instead of raw URL.
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
      let urlMatches = detector.matches(
        in: mutable.string,
        options: [],
        range: NSRange(mutable.string.startIndex..., in: mutable.string)
      ).reversed()
      for m in urlMatches {
        guard let url = m.url else { continue }
        var hasLink = false
        mutable.enumerateAttribute(.link, in: m.range, options: []) { value, _, stop in
          if value != nil { hasLink = true; stop.pointee = true }
        }
        if !hasLink {
          let display = cleanURLDisplay(url)
          var linkAttrs = baseAttrs
          linkAttrs[.link] = url
          linkAttrs[.foregroundColor] = UIColor.systemBlue
          linkAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
          mutable.replaceCharacters(
            in: m.range,
            with: NSAttributedString(string: display, attributes: linkAttrs)
          )
        }
      }
    }

    return mutable
  }

  private static func cleanURLDisplay(_ url: URL) -> String {
    guard let host = url.host else { return url.absoluteString }
    let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let path = url.path
    guard !path.isEmpty, path != "/" else { return h }
    let p = path.count > 28 ? String(path.prefix(28)) + "\u{2026}" : path
    return h + p
  }

  static func measuredHeight(
    for attributedText: NSAttributedString,
    width: CGFloat
  ) -> CGFloat {
    measuredSize(for: attributedText, width: width).height
  }

  static func measuredWidth(
    for attributedText: NSAttributedString,
    height: CGFloat
  ) -> CGFloat {
    guard height > 1.0, attributedText.length > 0 else { return 0.0 }
    let measured = attributedText.boundingRect(
      with: CGSize(width: .greatestFiniteMagnitude, height: height),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    return ceil(measured.width)
  }

  static func measuredSize(
    for attributedText: NSAttributedString,
    width: CGFloat
  ) -> CGSize {
    guard width > 1.0, attributedText.length > 0 else { return .zero }
    let measured = attributedText.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    return CGSize(width: ceil(measured.width), height: ceil(measured.height))
  }
}

// MARK: - AgentRuntimeSummaryView

final class AgentRuntimeSummaryView: UIView {
  private final class FileRowView: UIView {
    private let nameLabel = UILabel()
    private let pathLabel = UILabel()
    private let statsLabel = UILabel()
    private let statusLabel = UILabel()

    override init(frame: CGRect) {
      super.init(frame: frame)
      [nameLabel, pathLabel, statsLabel, statusLabel].forEach {
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.backgroundColor = .clear
        addSubview($0)
      }
      nameLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
      pathLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
      pathLabel.lineBreakMode = .byTruncatingMiddle
      statsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
      statsLabel.textAlignment = .right
      statusLabel.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
      statusLabel.textAlignment = .center
      statusLabel.layer.cornerRadius = 6
      statusLabel.layer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
      return nil
    }

    func configure(file: ChatListRow.AgentRuntimeFile, textColor: UIColor) {
      nameLabel.text = file.name
      pathLabel.text = file.path
      let additions = file.additions > 0 ? "+\(file.additions)" : "+0"
      let deletions = file.deletions > 0 ? "-\(file.deletions)" : "-0"
      statsLabel.text = "\(additions) \(deletions)"
      statusLabel.text = file.status

      nameLabel.textColor = textColor.withAlphaComponent(0.94)
      pathLabel.textColor = textColor.withAlphaComponent(0.56)
      statsLabel.textColor = UIColor.systemGreen
      if file.deletions > file.additions {
        statsLabel.textColor = UIColor.systemRed
      }
      statusLabel.textColor = textColor.withAlphaComponent(0.78)
      statusLabel.backgroundColor = textColor.withAlphaComponent(0.10)
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      let statusWidth: CGFloat = 34
      let statsWidth: CGFloat = 86
      let gap: CGFloat = 8
      statusLabel.frame = CGRect(x: 0, y: 7, width: statusWidth, height: 18)
      statsLabel.frame = CGRect(
        x: bounds.width - statsWidth,
        y: 7,
        width: statsWidth,
        height: 18
      )
      let textX = statusWidth + gap
      let textWidth = max(1, bounds.width - textX - statsWidth - gap)
      nameLabel.frame = CGRect(x: textX, y: 1, width: textWidth, height: 17)
      pathLabel.frame = CGRect(x: textX, y: 18, width: textWidth, height: 14)
    }
  }

  private let backgroundView = UIView()
  private let titleLabel = UILabel()
  private let statsLabel = UILabel()
  private let repoLabel = UILabel()
  private let commandLabel = UILabel()
  private let dirtyLabel = UILabel()
  private let moreLabel = UILabel()
  private var fileRows: [FileRowView] = []
  private var runtime: ChatListRow.AgentRuntimeSummary?
  private var textColor: UIColor = .label
  var onTap: ((ChatListRow.AgentRuntimeSummary) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    backgroundView.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.72)
    backgroundView.layer.cornerRadius = 12
    backgroundView.layer.cornerCurve = .continuous
    backgroundView.layer.borderWidth = 1
    backgroundView.layer.borderColor = UIColor.separator.withAlphaComponent(0.25).cgColor
    addSubview(backgroundView)

    [titleLabel, statsLabel, repoLabel, commandLabel, dirtyLabel, moreLabel].forEach {
      $0.backgroundColor = .clear
      $0.numberOfLines = 1
      addSubview($0)
    }
    titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    statsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    statsLabel.textAlignment = .right
    repoLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    commandLabel.font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    commandLabel.lineBreakMode = .byTruncatingMiddle
    dirtyLabel.font = UIFont.systemFont(ofSize: 11.5, weight: .regular)
    moreLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tap)
    isUserInteractionEnabled = true
  }

  required init?(coder: NSCoder) {
    return nil
  }

  static func measuredHeight(runtime: ChatListRow.AgentRuntimeSummary, availableWidth: CGFloat) -> CGFloat {
    _ = availableWidth
    let files = runtime.diff?.files ?? []
    var height: CGFloat = 14 + 22 + 18 + 8
    if runtime.command?.display?.isEmpty == false || runtime.command?.executable?.isEmpty == false {
      height += 18
    }
    if runtime.dirtyBefore {
      height += 17
    }
    height += CGFloat(min(files.count, 4)) * 34
    if files.count > 4 {
      height += 25
    }
    return max(82, height + 12)
  }

  @discardableResult
  func configure(
    runtime: ChatListRow.AgentRuntimeSummary,
    textColor: UIColor,
    availableWidth: CGFloat
  ) -> CGFloat {
    self.runtime = runtime
    self.textColor = textColor
    let diff = runtime.diff
    let filesChanged = diff?.filesChanged ?? 0
    titleLabel.text = filesChanged == 1 ? "1 file changed" : "\(filesChanged) files changed"
    statsLabel.text = "+\(diff?.additions ?? 0) -\(diff?.deletions ?? 0)"
    repoLabel.text = runtimeSubtitle(runtime)
    commandLabel.text = runtime.command?.display ?? runtime.command?.executable
    dirtyLabel.text =
      runtime.dirtyBefore
      ? "Repo already had \(runtime.dirtyBeforeCount) change(s) before this run"
      : nil
    let hiddenCount = max(0, (diff?.files.count ?? 0) - 4)
    moreLabel.text = hiddenCount > 0 ? "View \(hiddenCount) more file(s)" : nil

    titleLabel.textColor = textColor.withAlphaComponent(0.96)
    statsLabel.textColor = (diff?.deletions ?? 0) > (diff?.additions ?? 0)
      ? UIColor.systemRed : UIColor.systemGreen
    repoLabel.textColor = textColor.withAlphaComponent(0.62)
    commandLabel.textColor = textColor.withAlphaComponent(0.62)
    dirtyLabel.textColor = UIColor.systemOrange
    moreLabel.textColor = textColor.withAlphaComponent(0.62)

    let files = Array((diff?.files ?? []).prefix(4))
    while fileRows.count < files.count {
      let row = FileRowView()
      addSubview(row)
      fileRows.append(row)
    }
    for (index, row) in fileRows.enumerated() {
      if index < files.count {
        row.isHidden = false
        row.configure(file: files[index], textColor: textColor)
      } else {
        row.isHidden = true
      }
    }

    let height = Self.measuredHeight(runtime: runtime, availableWidth: availableWidth)
    frame.size = CGSize(width: availableWidth, height: height)
    setNeedsLayout()
    return height
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    backgroundView.frame = bounds
    let inset: CGFloat = 12
    let width = max(1, bounds.width - inset * 2)
    var y: CGFloat = 12
    let statsWidth: CGFloat = 96
    titleLabel.frame = CGRect(x: inset, y: y, width: max(1, width - statsWidth - 8), height: 22)
    statsLabel.frame = CGRect(x: bounds.width - inset - statsWidth, y: y + 1, width: statsWidth, height: 20)
    y += 24
    repoLabel.frame = CGRect(x: inset, y: y, width: width, height: 16)
    y += 20
    if !(commandLabel.text?.isEmpty ?? true) {
      commandLabel.isHidden = false
      commandLabel.frame = CGRect(x: inset, y: y, width: width, height: 16)
      y += 18
    } else {
      commandLabel.isHidden = true
      commandLabel.frame = .zero
    }
    if !(dirtyLabel.text?.isEmpty ?? true) {
      dirtyLabel.isHidden = false
      dirtyLabel.frame = CGRect(x: inset, y: y, width: width, height: 15)
      y += 17
    } else {
      dirtyLabel.isHidden = true
      dirtyLabel.frame = .zero
    }

    for row in fileRows where !row.isHidden {
      row.frame = CGRect(x: inset, y: y, width: width, height: 32)
      y += 34
    }
    if !(moreLabel.text?.isEmpty ?? true) {
      moreLabel.isHidden = false
      moreLabel.frame = CGRect(x: inset, y: y + 2, width: width, height: 18)
    } else {
      moreLabel.isHidden = true
      moreLabel.frame = .zero
    }
  }

  private func runtimeSubtitle(_ runtime: ChatListRow.AgentRuntimeSummary) -> String {
    var parts: [String] = []
    if let provider = runtime.provider, !provider.isEmpty {
      let title = provider.prefix(1).uppercased() + String(provider.dropFirst())
      parts.append(title)
    }
    if let repo = runtime.repoName, !repo.isEmpty {
      parts.append(repo)
    }
    if let mode = runtime.workMode, !mode.isEmpty {
      parts.append(mode.replacingOccurrences(of: "_", with: " "))
    }
    if let model = runtime.model, !model.isEmpty {
      parts.append(model)
    }
    if let exit = runtime.exitStatus, runtime.status == "failed" {
      parts.append("exit \(exit)")
    }
    return parts.isEmpty ? "Local bridge" : parts.joined(separator: " · ")
  }

  @objc private func handleTap() {
    guard let runtime else { return }
    onTap?(runtime)
  }
}

// MARK: - AgentRuntimeTaskViewController

final class AgentRuntimeTaskViewController: UIViewController {
  private let row: ChatListRow
  private let runtime: ChatListRow.AgentRuntimeSummary
  private let appearance: ChatListAppearance
  private let chatId: String
  private let fallbackProvider: String?

  private let messagesView = ChatNativeAgentMessagesView()
  private let actionBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
  private let actionStack = UIStackView()
  private let filesButton = UIButton(type: .system)
  private let copyPatchButton = UIButton(type: .system)
  private let stopButton = UIButton(type: .system)
  private let revertButton = UIButton(type: .system)
  private let statusLabel = UILabel()

  init(
    row: ChatListRow,
    runtime: ChatListRow.AgentRuntimeSummary,
    appearance: ChatListAppearance,
    chatId: String,
    fallbackProvider: String?
  ) {
    self.row = row
    self.runtime = runtime
    self.appearance = appearance
    self.chatId = chatId
    self.fallbackProvider = fallbackProvider
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = appearance.isDark ? .black : .systemBackground
    title = runtime.provider?.capitalized ?? fallbackProvider?.capitalized ?? "Agent"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done,
      target: self,
      action: #selector(handleDone)
    )

    messagesView.translatesAutoresizingMaskIntoConstraints = false
    messagesView.applyAppearance(appearance)
    view.addSubview(messagesView)

    actionBar.translatesAutoresizingMaskIntoConstraints = false
    actionBar.layer.cornerRadius = 20
    actionBar.layer.cornerCurve = .continuous
    actionBar.clipsToBounds = true
    view.addSubview(actionBar)

    actionStack.axis = .horizontal
    actionStack.alignment = .fill
    actionStack.distribution = .fillEqually
    actionStack.spacing = 8
    actionStack.translatesAutoresizingMaskIntoConstraints = false
    actionBar.contentView.addSubview(actionStack)

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    statusLabel.textColor = appearance.isDark ? UIColor.white.withAlphaComponent(0.58) : .secondaryLabel
    statusLabel.textAlignment = .center
    actionBar.contentView.addSubview(statusLabel)

    configureActionButton(filesButton, title: "Files", symbolName: "doc.text.magnifyingglass")
    configureActionButton(copyPatchButton, title: "Patch", symbolName: "doc.on.doc")
    configureActionButton(stopButton, title: "Stop", symbolName: "stop.fill")
    configureActionButton(revertButton, title: "Revert", symbolName: "arrow.uturn.backward")

    filesButton.addTarget(self, action: #selector(handleFiles), for: .touchUpInside)
    copyPatchButton.addTarget(self, action: #selector(handleCopyPatch), for: .touchUpInside)
    stopButton.addTarget(self, action: #selector(handleStop), for: .touchUpInside)
    revertButton.addTarget(self, action: #selector(handleRevert), for: .touchUpInside)

    actionStack.addArrangedSubview(filesButton)
    actionStack.addArrangedSubview(copyPatchButton)
    actionStack.addArrangedSubview(stopButton)
    actionStack.addArrangedSubview(revertButton)

    let hasPatch = runtime.diff?.patch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    let hasFiles = !(runtime.diff?.files ?? []).isEmpty
    filesButton.isEnabled = hasFiles
    filesButton.alpha = hasFiles ? 1.0 : 0.42
    copyPatchButton.isEnabled = hasPatch
    copyPatchButton.alpha = hasPatch ? 1.0 : 0.42
    stopButton.isEnabled = runtime.controls?.canCancel == true || runtime.status == "running"
    stopButton.alpha = stopButton.isEnabled ? 1.0 : 0.42
    revertButton.isEnabled = runtime.controls?.canRevert == true
    revertButton.alpha = revertButton.isEnabled ? 1.0 : 0.42

    NSLayoutConstraint.activate([
      messagesView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      messagesView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      messagesView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      messagesView.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -10),

      actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      actionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
      actionBar.heightAnchor.constraint(equalToConstant: 86),

      statusLabel.leadingAnchor.constraint(equalTo: actionBar.contentView.leadingAnchor, constant: 12),
      statusLabel.trailingAnchor.constraint(equalTo: actionBar.contentView.trailingAnchor, constant: -12),
      statusLabel.topAnchor.constraint(equalTo: actionBar.contentView.topAnchor, constant: 8),
      statusLabel.heightAnchor.constraint(equalToConstant: 16),

      actionStack.leadingAnchor.constraint(equalTo: actionBar.contentView.leadingAnchor, constant: 10),
      actionStack.trailingAnchor.constraint(equalTo: actionBar.contentView.trailingAnchor, constant: -10),
      actionStack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
      actionStack.bottomAnchor.constraint(equalTo: actionBar.contentView.bottomAnchor, constant: -10),
    ])

    statusLabel.text = statusText()
    messagesView.setRows(
      buildRawRows(),
      topPadding: 10,
      spacerHeight: 0,
      bottomPadding: 18,
      scrollToBottom: false,
      animated: false
    )
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    messagesView.scrollToBottom(animated: false)
  }

  private func configureActionButton(_ button: UIButton, title: String, symbolName: String) {
    var config = UIButton.Configuration.filled()
    config.title = title
    config.image = UIImage(systemName: symbolName)
    config.imagePadding = 5
    config.cornerStyle = .large
    config.baseForegroundColor = appearance.isDark ? .white : .label
    config.baseBackgroundColor =
      appearance.isDark
      ? UIColor.white.withAlphaComponent(0.10)
      : UIColor.black.withAlphaComponent(0.06)
    button.configuration = config
    button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
  }

  private func buildRawRows() -> [[String: Any]] {
    var rows: [[String: Any]] = []
    let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
    rows.append([
      "kind": "day",
      "key": "runtime-day-\(row.messageId ?? row.key)",
      "label": "Task",
      "timestampMs": timestampMs,
    ])

    let resultText = (row.plainContent ?? row.text).trimmingCharacters(in: .whitespacesAndNewlines)
    let runtimeMessageId = row.messageId ?? row.key
    rows.append(agentMessageRow(
      key: "runtime-result-\(runtimeMessageId)",
      id: runtimeMessageId,
      text: resultText.isEmpty ? statusText() : resultText,
      timestamp: row.timestamp,
      metadata: ["agentRuntime": runtimePayloadDictionary(runtime)]
    ))

    let details = runtimeDetailsText().trimmingCharacters(in: .whitespacesAndNewlines)
    if !details.isEmpty {
      rows.append(agentMessageRow(
        key: "runtime-details-\(runtimeMessageId)",
        id: "\(runtimeMessageId)-details",
        text: details,
        timestamp: row.timestamp,
        metadata: [:]
      ))
    }

    if let patch = runtime.diff?.patch?.trimmingCharacters(in: .whitespacesAndNewlines), !patch.isEmpty {
      let truncated = runtime.diff?.patchTruncated == true ? "\n\nPatch truncated by bridge payload limit." : ""
      rows.append(agentMessageRow(
        key: "runtime-patch-\(runtimeMessageId)",
        id: "\(runtimeMessageId)-patch",
        text: "```diff\n\(patch)\n```\n\(truncated)",
        timestamp: row.timestamp,
        metadata: [:]
      ))
    }

    return rows
  }

  private func agentMessageRow(
    key: String,
    id: String,
    text: String,
    timestamp: String,
    metadata: [String: Any]
  ) -> [String: Any] {
    var message: [String: Any] = [
      "id": id,
      "text": text,
      "plainContent": text,
      "timestamp": timestamp,
      "isMe": false,
      "type": "text",
      "isAgentMessage": true,
      "agentName": runtime.provider?.capitalized ?? fallbackProvider?.capitalized ?? "Agent",
      "metadata": metadata,
      "bubbleShape": [
        "showTail": true,
        "borderTopLeftRadius": 18,
        "borderTopRightRadius": 18,
        "borderBottomLeftRadius": 18,
        "borderBottomRightRadius": 18,
      ],
    ]

    if metadata.isEmpty {
      message.removeValue(forKey: "metadata")
    }

    return [
      "kind": "message",
      "key": key,
      "message": message,
    ]
  }

  private func runtimePayloadDictionary(_ runtime: ChatListRow.AgentRuntimeSummary) -> [String: Any] {
    var payload: [String: Any] = [
      "status": runtime.status,
      "dirtyBefore": runtime.dirtyBefore,
      "dirtyBeforeCount": runtime.dirtyBeforeCount,
    ]
    put(runtime.taskId, into: &payload, key: "taskId")
    put(runtime.provider, into: &payload, key: "provider")
    put(runtime.repoName, into: &payload, key: "repoName")
    put(runtime.cwd, into: &payload, key: "cwd")
    put(runtime.workMode, into: &payload, key: "workMode")
    put(runtime.model, into: &payload, key: "model")
    put(runtime.permissionMode, into: &payload, key: "permissionMode")
    put(runtime.sessionId, into: &payload, key: "sessionId")
    put(runtime.threadId, into: &payload, key: "threadId")
    put(runtime.cliVersion, into: &payload, key: "cliVersion")
    if let durationMs = runtime.durationMs { payload["durationMs"] = durationMs }
    if let exitStatus = runtime.exitStatus { payload["exitStatus"] = exitStatus }
    if let command = runtime.command {
      var commandPayload: [String: Any] = [:]
      put(command.executable, into: &commandPayload, key: "executable")
      put(command.display, into: &commandPayload, key: "display")
      payload["command"] = commandPayload
    }
    if let diff = runtime.diff {
      payload["diff"] = [
        "filesChanged": diff.filesChanged,
        "additions": diff.additions,
        "deletions": diff.deletions,
        "files": diff.files.map { file in
          [
            "path": file.path,
            "name": file.name,
            "status": file.status,
            "additions": file.additions,
            "deletions": file.deletions,
          ]
        },
        "patch": diff.patch ?? "",
        "patchTruncated": diff.patchTruncated,
      ]
    }
    if let controls = runtime.controls {
      payload["controls"] = [
        "canCancel": controls.canCancel,
        "canRevert": controls.canRevert,
      ]
    }
    if let usage = runtime.usage {
      var usagePayload: [String: Any] = [:]
      if let value = usage.inputTokens { usagePayload["inputTokens"] = value }
      if let value = usage.cachedInputTokens { usagePayload["cachedInputTokens"] = value }
      if let value = usage.cacheCreationInputTokens { usagePayload["cacheCreationInputTokens"] = value }
      if let value = usage.outputTokens { usagePayload["outputTokens"] = value }
      if let value = usage.reasoningOutputTokens { usagePayload["reasoningOutputTokens"] = value }
      if let value = usage.totalCostUsd { usagePayload["totalCostUsd"] = value }
      if let value = usage.durationMs { usagePayload["durationMs"] = value }
      if let value = usage.durationApiMs { usagePayload["durationApiMs"] = value }
      if let value = usage.ttftMs { usagePayload["ttftMs"] = value }
      if let value = usage.ttftStreamMs { usagePayload["ttftStreamMs"] = value }
      if let value = usage.numTurns { usagePayload["numTurns"] = value }
      if !usagePayload.isEmpty { payload["usage"] = usagePayload }
    }
    if !runtime.availableTools.isEmpty { payload["availableTools"] = runtime.availableTools }
    if !runtime.slashCommands.isEmpty { payload["slashCommands"] = runtime.slashCommands }
    if !runtime.cliCommands.isEmpty { payload["cliCommands"] = runtime.cliCommands }
    if !runtime.providerCommands.isEmpty { payload["providerCommands"] = runtime.providerCommands }
    if !runtime.mcpServers.isEmpty {
      payload["mcpServers"] = runtime.mcpServers.map { server in
        var item: [String: Any] = ["name": server.name]
        put(server.status, into: &item, key: "status")
        return item
      }
    }
    if !runtime.agents.isEmpty { payload["agents"] = runtime.agents }
    if !runtime.skills.isEmpty { payload["skills"] = runtime.skills }
    return payload
  }

  private func put(_ value: String?, into payload: inout [String: Any], key: String) {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    payload[key] = value
  }

  private func statusText() -> String {
    var parts: [String] = []
    if let repo = runtime.repoName, !repo.isEmpty { parts.append(repo) }
    if let cwd = runtime.cwd, !cwd.isEmpty { parts.append(cwd) }
    if let mode = runtime.workMode, !mode.isEmpty {
      parts.append(mode.replacingOccurrences(of: "_", with: " "))
    }
    if let duration = runtime.durationMs, duration > 0 {
      parts.append(String(format: "%.1fs", Double(duration) / 1000.0))
    }
    if runtime.status == "failed", let exit = runtime.exitStatus {
      parts.append("exit \(exit)")
    } else {
      parts.append(runtime.status)
    }
    return parts.joined(separator: "  ")
  }

  private func runtimeDetailsText() -> String {
    var sections: [String] = []
    var overview: [String] = []
    if let model = runtime.model, !model.isEmpty { overview.append("model: \(model)") }
    if let permission = runtime.permissionMode, !permission.isEmpty { overview.append("permission: \(permission)") }
    if let cli = runtime.cliVersion, !cli.isEmpty { overview.append("cli: \(cli)") }
    if let session = runtime.sessionId, !session.isEmpty { overview.append("session: \(shortId(session))") }
    if let thread = runtime.threadId, !thread.isEmpty { overview.append("thread: \(shortId(thread))") }
    if !overview.isEmpty {
      sections.append("Runtime\n" + overview.joined(separator: "\n"))
    }
    if let usageText = usageText(runtime.usage) {
      sections.append("Usage\n\(usageText)")
    }
    if !runtime.providerCommands.isEmpty {
      sections.append("Bridge commands\n" + runtime.providerCommands.prefix(8).joined(separator: "  "))
    }
    if !runtime.slashCommands.isEmpty {
      sections.append("Provider slash commands\n" + runtime.slashCommands.prefix(18).map { "/\($0)" }.joined(separator: "  "))
    }
    if !runtime.cliCommands.isEmpty {
      sections.append("CLI commands\n" + runtime.cliCommands.prefix(18).joined(separator: "  "))
    }
    if !runtime.availableTools.isEmpty {
      sections.append("Tools\n" + runtime.availableTools.prefix(20).joined(separator: "  "))
    }
    if !runtime.mcpServers.isEmpty {
      sections.append("MCP\n" + runtime.mcpServers.prefix(8).map { server in
        if let status = server.status, !status.isEmpty {
          return "\(server.name): \(status)"
        }
        return server.name
      }.joined(separator: "\n"))
    }
    return sections.joined(separator: "\n\n")
  }

  private func usageText(_ usage: ChatListRow.AgentRuntimeUsage?) -> String? {
    guard let usage else { return nil }
    var parts: [String] = []
    if let value = usage.inputTokens { parts.append("input \(value)") }
    if let value = usage.cachedInputTokens { parts.append("cached \(value)") }
    if let value = usage.outputTokens { parts.append("output \(value)") }
    if let value = usage.reasoningOutputTokens { parts.append("reasoning \(value)") }
    if let value = usage.totalCostUsd { parts.append(String(format: "cost $%.4f", value)) }
    if let value = usage.ttftMs { parts.append(String(format: "ttft %.1fs", Double(value) / 1000.0)) }
    if let value = usage.durationMs { parts.append(String(format: "duration %.1fs", Double(value) / 1000.0)) }
    return parts.isEmpty ? nil : parts.joined(separator: "  ")
  }

  private func shortId(_ value: String) -> String {
    guard value.count > 12 else { return value }
    return "\(value.prefix(8))...\(value.suffix(4))"
  }

  private func providerForControl() -> String? {
    let provider = runtime.provider ?? fallbackProvider
    let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  @objc private func handleDone() {
    dismiss(animated: true)
  }

  @objc private func handleFiles() {
    guard let diff = runtime.diff, !diff.files.isEmpty else { return }
    let controller = AgentRuntimeFilesViewController(runtime: runtime, appearance: appearance)
    navigationController?.pushViewController(controller, animated: true)
  }

  @objc private func handleCopyPatch() {
    guard let patch = runtime.diff?.patch, !patch.isEmpty else { return }
    UIPasteboard.general.string = patch
    statusLabel.text = "Patch copied"
  }

  @objc private func handleStop() {
    sendControl(action: "cancel", button: stopButton, pendingTitle: "Stopping", doneTitle: "Stop Sent")
  }

  @objc private func handleRevert() {
    let alert = UIAlertController(
      title: "Revert Task Changes",
      message: "This asks the bridge to revert only the files reported by this task.",
      preferredStyle: .actionSheet
    )
    alert.addAction(UIAlertAction(title: "Revert", style: .destructive) { [weak self] _ in
      self?.sendControl(action: "revert", button: self?.revertButton, pendingTitle: "Reverting", doneTitle: "Revert Sent")
    })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = alert.popoverPresentationController {
      popover.sourceView = revertButton
      popover.sourceRect = revertButton.bounds
    }
    present(alert, animated: true)
  }

  private func sendControl(
    action: String,
    button: UIButton?,
    pendingTitle: String,
    doneTitle: String
  ) {
    guard let provider = providerForControl(), !chatId.isEmpty else {
      statusLabel.text = "Bridge control unavailable"
      return
    }
    button?.isEnabled = false
    statusLabel.text = pendingTitle
    var payload: [String: Any] = [
      "chatId": chatId,
      "provider": provider,
      "action": action,
    ]
    if let taskId = runtime.taskId, !taskId.isEmpty {
      payload["taskId"] = taskId
    }
    let result = ChatEngine.shared.sendAgentBridgeControl(payload)
    if (result["accepted"] as? Bool) == true {
      statusLabel.text = doneTitle
    } else {
      let reason = (result["reason"] as? String) ?? "not accepted"
      statusLabel.text = "Control failed: \(reason)"
      button?.isEnabled = true
    }
  }
}

final class AgentRuntimeFilesViewController: UITableViewController {
  private let runtime: ChatListRow.AgentRuntimeSummary
  private let appearance: ChatListAppearance
  private let files: [ChatListRow.AgentRuntimeFile]
  private let chatId: String?
  private let provider: String?

  init(
    runtime: ChatListRow.AgentRuntimeSummary,
    appearance: ChatListAppearance,
    chatId: String? = nil,
    provider: String? = nil
  ) {
    self.runtime = runtime
    self.appearance = appearance
    self.files = runtime.diff?.files ?? []
    self.chatId = chatId
    self.provider = provider
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Files"
    view.backgroundColor = appearance.isDark ? .black : .systemGroupedBackground
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "file")
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    files.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  ) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath)
    let file = files[indexPath.row]
    var content = UIListContentConfiguration.subtitleCell()
    content.text = file.name
    content.secondaryText = "\(file.path)   +\(file.additions) -\(file.deletions)"
    content.textProperties.font = .systemFont(ofSize: 15, weight: .semibold)
    content.secondaryTextProperties.font = .systemFont(ofSize: 12, weight: .regular)
    cell.contentConfiguration = content
    cell.accessoryType = .disclosureIndicator
    cell.backgroundColor = appearance.isDark ? UIColor.white.withAlphaComponent(0.06) : .secondarySystemGroupedBackground
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let file = files[indexPath.row]
    let controller = AgentRuntimePatchPreviewController(
      file: file,
      patch: runtime.diff?.patch ?? "",
      patchTruncated: runtime.diff?.patchTruncated == true,
      appearance: appearance,
      chatId: chatId,
      provider: provider ?? runtime.provider,
      presentedAsSheet: true
    )
    // The +/- patch opens as a bottom sheet (not another pushed page), so the file
    // list stays underneath and the user can flick between files quickly.
    let nav = UINavigationController(rootViewController: controller)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 20
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    present(nav, animated: true)
  }
}

private final class AgentRuntimePatchPreviewController: UIViewController {
  private let file: ChatListRow.AgentRuntimeFile
  private let patch: String
  private let patchTruncated: Bool
  private let appearance: ChatListAppearance
  private let chatId: String?
  private let provider: String?
  private let presentedAsSheet: Bool
  private let textView = UITextView()

  init(
    file: ChatListRow.AgentRuntimeFile,
    patch: String,
    patchTruncated: Bool,
    appearance: ChatListAppearance,
    chatId: String? = nil,
    provider: String? = nil,
    presentedAsSheet: Bool = false
  ) {
    self.file = file
    self.patch = patch
    self.patchTruncated = patchTruncated
    self.appearance = appearance
    self.chatId = chatId
    self.provider = provider
    self.presentedAsSheet = presentedAsSheet
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = file.name
    view.backgroundColor = appearance.isDark ? .black : .systemBackground
    var rightItems = [
      UIBarButtonItem(
        image: UIImage(systemName: "doc.on.doc"),
        style: .plain,
        target: self,
        action: #selector(handleCopy)
      )
    ]
    // Open the FULL file (fetched from the bridge, E2E) when we know the chat +
    // provider to route the request — like the Codex/ChatGPT mobile file view.
    if let chatId, !chatId.isEmpty, let provider, !provider.isEmpty {
      rightItems.append(
        UIBarButtonItem(
          image: UIImage(systemName: "doc.text.magnifyingglass"),
          style: .plain,
          target: self,
          action: #selector(handleOpenFile)
        )
      )
    }
    navigationItem.rightBarButtonItems = rightItems
    if presentedAsSheet {
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: self,
        action: #selector(handleDone)
      )
    }

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.alwaysBounceVertical = true
    textView.backgroundColor = .clear
    textView.textColor = appearance.isDark ? .white : .label
    textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
    view.addSubview(textView)

    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    textView.attributedText = attributedPreview()
  }

  private func previewText() -> String {
    let chunk = diffChunk(for: file.path, patch: patch)
    if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return patchTruncated ? chunk + "\n\n[Patch truncated]" : chunk
    }
    return """
    \(file.path)
    status: \(file.status)
    additions: \(file.additions)
    deletions: \(file.deletions)

    No per-file patch was included in this payload.
    """
  }

  /// Renders the unified diff with GitHub-style coloring: added lines green,
  /// removed lines red, hunk headers tinted, file metadata muted.
  private func attributedPreview() -> NSAttributedString {
    let font = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    let baseColor: UIColor = appearance.isDark ? .white : .label
    let muted: UIColor = appearance.isDark
      ? UIColor.white.withAlphaComponent(0.45) : UIColor.label.withAlphaComponent(0.45)
    let addText = UIColor.systemGreen
    let delText = UIColor.systemRed
    let addBg = UIColor.systemGreen.withAlphaComponent(appearance.isDark ? 0.16 : 0.12)
    let delBg = UIColor.systemRed.withAlphaComponent(appearance.isDark ? 0.16 : 0.12)
    let hunkColor: UIColor = appearance.isDark
      ? UIColor.systemTeal : UIColor.systemBlue

    let result = NSMutableAttributedString()
    let lines = previewText().components(separatedBy: "\n")
    for (idx, line) in lines.enumerated() {
      let text = idx == lines.count - 1 ? line : line + "\n"
      var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: baseColor]
      if line.hasPrefix("+++") || line.hasPrefix("---")
        || line.hasPrefix("diff --git") || line.hasPrefix("index ")
        || line.hasPrefix("new file") || line.hasPrefix("deleted file")
        || line.hasPrefix("rename ") || line.hasPrefix("similarity ") {
        attrs[.foregroundColor] = muted
      } else if line.hasPrefix("@@") {
        attrs[.foregroundColor] = hunkColor
      } else if line.hasPrefix("+") {
        attrs[.foregroundColor] = addText
        attrs[.backgroundColor] = addBg
      } else if line.hasPrefix("-") {
        attrs[.foregroundColor] = delText
        attrs[.backgroundColor] = delBg
      } else if line.hasPrefix("[Patch truncated]") {
        attrs[.foregroundColor] = muted
      }
      result.append(NSAttributedString(string: text, attributes: attrs))
    }
    return result
  }

  @objc private func handleDone() {
    dismiss(animated: true)
  }

  private func diffChunk(for path: String, patch: String) -> String {
    let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var chunks: [[String]] = []
    var current: [String] = []

    for line in lines {
      if line.hasPrefix("diff --git ") && !current.isEmpty {
        chunks.append(current)
        current = [line]
      } else {
        current.append(line)
      }
    }
    if !current.isEmpty { chunks.append(current) }

    for chunk in chunks {
      let joined = chunk.joined(separator: "\n")
      if joined.contains(" b/\(path)") || joined.contains(" a/\(path)")
        || joined.contains("+++ b/\(path)") || joined.contains("--- a/\(path)")
      {
        return joined
      }
    }
    return ""
  }

  @objc private func handleCopy() {
    UIPasteboard.general.string = textView.text
  }

  @objc private func handleOpenFile() {
    guard let chatId, let provider else { return }
    let viewer = AgentBridgeFileViewerController(
      chatId: chatId,
      provider: provider,
      path: file.path,
      fileName: file.name,
      appearance: appearance
    )
    if let nav = navigationController {
      // Inside a sheet, expand to full height first so the file is readable.
      if let sheet = nav.sheetPresentationController {
        sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
      }
      nav.pushViewController(viewer, animated: true)
    } else {
      present(UINavigationController(rootViewController: viewer), animated: true)
    }
  }
}

// MARK: - AgentBridgeFileViewerController

/// Shows the FULL contents of a file the agent touched, fetched on demand from
/// the user's bridge. The bytes travel E2E-encrypted (`agentFileEnc`); the
/// server only relays the opaque blob. Mirrors the Codex/ChatGPT mobile file view.
final class AgentBridgeFileViewerController: UIViewController {
  private let chatId: String
  private let provider: String
  private let path: String
  private let fileName: String
  private let appearance: ChatListAppearance
  private let requestId = UUID().uuidString

  private let textView = UITextView()
  private let spinner = UIActivityIndicatorView(style: .large)
  private let statusLabel = UILabel()
  private var observer: NSObjectProtocol?
  private var finished = false

  init(
    chatId: String,
    provider: String,
    path: String,
    fileName: String,
    appearance: ChatListAppearance
  ) {
    self.chatId = chatId
    self.provider = provider
    self.path = path
    self.fileName = fileName
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = fileName
    view.backgroundColor = appearance.isDark ? .black : .systemBackground
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "doc.on.doc"),
      style: .plain,
      target: self,
      action: #selector(handleCopy)
    )

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.isHidden = true
    textView.alwaysBounceVertical = true
    textView.backgroundColor = .clear
    textView.textColor = appearance.isDark ? .white : .label
    textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
    view.addSubview(textView)

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .center
    statusLabel.font = .systemFont(ofSize: 14)
    statusLabel.textColor = appearance.isDark ? UIColor.white.withAlphaComponent(0.6) : .secondaryLabel
    statusLabel.text = "Loading file from your computer…"
    view.addSubview(statusLabel)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = appearance.isDark ? .white : .gray
    spinner.startAnimating()
    view.addSubview(spinner)

    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
    ])

    observer = NotificationCenter.default.addObserver(
      forName: ChatEngine.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self else { return }
      guard (note.userInfo?["reason"] as? String) == "agentBridgeFile" else { return }
      guard (note.userInfo?["requestId"] as? String) == self.requestId else { return }
      self.deliver()
    }

    let result = ChatEngine.shared.requestAgentBridgeFile([
      "chatId": chatId,
      "provider": provider,
      "path": path,
      "requestId": requestId,
    ])
    if (result["accepted"] as? Bool) != true {
      let reason = (result["reason"] as? String) ?? "request_failed"
      fail("Couldn't reach your computer (\(reason)). Make sure the bridge is running.")
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
      guard let self, !self.finished else { return }
      self.fail("Timed out waiting for the file from your computer.")
    }
  }

  private func deliver() {
    guard !finished else { return }
    guard let payload = ChatEngine.shared.latestAgentBridgeFile(requestId: requestId) else { return }
    if (payload["ok"] as? Bool) == false {
      fail((payload["message"] as? String) ?? "The file could not be read.")
      return
    }
    guard let decrypted = AgentRuntimeCrypto.decrypt(payload["agentFileEnc"]),
      let content = decrypted["content"] as? String
    else {
      fail("This file is sealed and can't be opened on this phone yet — sync the encryption key from the bridge.")
      return
    }
    finished = true
    spinner.stopAnimating()
    statusLabel.isHidden = true
    textView.isHidden = false
    let truncated = (decrypted["truncated"] as? Bool) == true
    textView.text = truncated ? content + "\n\n[File truncated — too large to show in full]" : content
  }

  private func fail(_ message: String) {
    guard !finished else { return }
    finished = true
    spinner.stopAnimating()
    textView.isHidden = true
    statusLabel.isHidden = false
    statusLabel.text = message
  }

  @objc private func handleCopy() {
    UIPasteboard.general.string = textView.text
  }
}

// MARK: - AgentIntegrationPackView

final class AgentIntegrationPackView: UIControl, UIGestureRecognizerDelegate {
  private static var expandedStorageKeys = Set<String>()
  private static let collapsedHeight: CGFloat = 72.0

  private let cardView = UIView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let actionLabel = UILabel()
  private let chevronView = UIImageView()
  private let dividerView = UIView()
  private let environmentTitleLabel = UILabel()
  private let environmentView = UIView()
  private let environmentLabel = UILabel()
  private let copyButton = UIButton(type: .system)
  private let endpointsTitleLabel = UILabel()
  private let endpointsLabel = UILabel()

  private var currentPack: AgentIntegrationPack?
  private var currentStorageKey = ""
  private var currentAvailableWidth: CGFloat = 0
  private var currentTextColor = UIColor.label
  private var isExpanded = false

  static func isExpanded(pack: AgentIntegrationPack, storageKey: String? = nil) -> Bool {
    expandedStorageKeys.contains(resolvedStorageKey(pack: pack, storageKey: storageKey))
  }

  static func measuredHeight(
    pack: AgentIntegrationPack,
    availableWidth: CGFloat,
    storageKey: String? = nil
  ) -> CGFloat {
    guard isExpanded(pack: pack, storageKey: storageKey) else { return collapsedHeight }

    let horizontalPadding: CGFloat = 12.0
    let environmentWidth = max(1.0, availableWidth - (horizontalPadding * 4.0) - 34.0)
    let environmentFont = UIFont.monospacedSystemFont(ofSize: 12.0, weight: .regular)
    let environmentHeight = ceil(
      (pack.environment as NSString).boundingRect(
        with: CGSize(width: environmentWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: environmentFont],
        context: nil
      ).height
    )
    let endpointCount = [pack.eventsURL, pack.invokeURL].compactMap { $0 }.count
    let endpointsHeight: CGFloat = endpointCount > 0 ? CGFloat(endpointCount) * 19.0 : 0.0
    return collapsedHeight + 1.0 + 30.0 + max(42.0, environmentHeight + 20.0)
      + (endpointCount > 0 ? 30.0 + endpointsHeight : 0.0) + 12.0
  }

  private static func resolvedStorageKey(
    pack: AgentIntegrationPack,
    storageKey: String?
  ) -> String {
    let override = storageKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return override.isEmpty ? pack.storageKey : override
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    cardView.isUserInteractionEnabled = true
    cardView.layer.cornerRadius = 14.0
    cardView.layer.cornerCurve = .continuous
    cardView.clipsToBounds = true
    addSubview(cardView)

    iconView.contentMode = .center
    iconView.layer.cornerRadius = 18.0
    iconView.layer.cornerCurve = .continuous
    cardView.addSubview(iconView)

    titleLabel.font = .systemFont(ofSize: 14.0, weight: .semibold)
    cardView.addSubview(titleLabel)

    subtitleLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
    subtitleLabel.lineBreakMode = .byTruncatingTail
    cardView.addSubview(subtitleLabel)

    actionLabel.font = .systemFont(ofSize: 12.0, weight: .semibold)
    actionLabel.textAlignment = .right
    cardView.addSubview(actionLabel)

    chevronView.contentMode = .scaleAspectFit
    cardView.addSubview(chevronView)

    cardView.addSubview(dividerView)

    environmentTitleLabel.text = "ENVIRONMENT"
    environmentTitleLabel.font = .systemFont(ofSize: 10.0, weight: .semibold)
    cardView.addSubview(environmentTitleLabel)

    environmentView.layer.cornerRadius = 10.0
    environmentView.layer.cornerCurve = .continuous
    cardView.addSubview(environmentView)

    environmentLabel.numberOfLines = 0
    environmentLabel.font = .monospacedSystemFont(ofSize: 12.0, weight: .regular)
    environmentView.addSubview(environmentLabel)

    copyButton.setImage(
      UIImage(
        systemName: "doc.on.doc",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .medium)
      ),
      for: .normal
    )
    copyButton.addTarget(self, action: #selector(handleCopy), for: .touchUpInside)
    environmentView.addSubview(copyButton)

    endpointsTitleLabel.text = "ENDPOINTS"
    endpointsTitleLabel.font = .systemFont(ofSize: 10.0, weight: .semibold)
    cardView.addSubview(endpointsTitleLabel)

    endpointsLabel.numberOfLines = 0
    endpointsLabel.font = .monospacedSystemFont(ofSize: 11.0, weight: .regular)
    endpointsLabel.lineBreakMode = .byTruncatingMiddle
    cardView.addSubview(endpointsLabel)

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleToggle))
    tapGesture.delegate = self
    cardView.addGestureRecognizer(tapGesture)
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { return nil }

  @discardableResult
  func configure(
    pack: AgentIntegrationPack,
    textColor: UIColor,
    availableWidth: CGFloat,
    storageKey: String? = nil
  ) -> CGFloat {
    currentPack = pack
    currentAvailableWidth = availableWidth
    currentTextColor = textColor
    currentStorageKey = Self.resolvedStorageKey(pack: pack, storageKey: storageKey)
    isExpanded = Self.expandedStorageKeys.contains(currentStorageKey)

    let accent = UIColor.systemTeal
    cardView.backgroundColor = textColor.withAlphaComponent(0.055)
    cardView.layer.borderWidth = 0.5
    cardView.layer.borderColor = textColor.withAlphaComponent(0.14).cgColor
    iconView.backgroundColor = accent.withAlphaComponent(0.16)
    iconView.tintColor = accent
    iconView.image = UIImage(
      systemName: "shippingbox.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold)
    )
    titleLabel.text = "Agent pack"
    titleLabel.textColor = textColor
    let identity = pack.username.map { "@\($0)" } ?? pack.displayName
    subtitleLabel.text = "\(identity)  •  \(pack.status.capitalized)"
    subtitleLabel.textColor = textColor.withAlphaComponent(0.62)
    actionLabel.text = isExpanded ? "Close" : "Open"
    actionLabel.textColor = accent
    chevronView.tintColor = accent
    chevronView.image = UIImage(
      systemName: isExpanded ? "chevron.up" : "chevron.down",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 10.0, weight: .semibold)
    )
    dividerView.backgroundColor = textColor.withAlphaComponent(0.10)
    environmentTitleLabel.textColor = textColor.withAlphaComponent(0.48)
    environmentView.backgroundColor = textColor.withAlphaComponent(0.055)
    environmentLabel.text = pack.environment
    environmentLabel.textColor = textColor.withAlphaComponent(0.86)
    copyButton.tintColor = accent
    endpointsTitleLabel.textColor = textColor.withAlphaComponent(0.48)
    endpointsLabel.text = [
      pack.eventsURL.map { "Events  \($0)" },
      pack.invokeURL.map { "Invoke  \($0)" },
    ].compactMap { $0 }.joined(separator: "\n")
    endpointsLabel.textColor = accent

    let hasEndpoints = !(endpointsLabel.text ?? "").isEmpty
    dividerView.isHidden = !isExpanded
    environmentTitleLabel.isHidden = !isExpanded
    environmentView.isHidden = !isExpanded
    endpointsTitleLabel.isHidden = !isExpanded || !hasEndpoints
    endpointsLabel.isHidden = !isExpanded || !hasEndpoints

    let height = Self.measuredHeight(
      pack: pack,
      availableWidth: availableWidth,
      storageKey: currentStorageKey
    )
    cardView.frame = CGRect(x: 0.0, y: 0.0, width: availableWidth, height: height)

    iconView.frame = CGRect(x: 12.0, y: 18.0, width: 36.0, height: 36.0)
    let chevronWidth: CGFloat = 12.0
    chevronView.frame = CGRect(
      x: availableWidth - 12.0 - chevronWidth,
      y: 30.0,
      width: chevronWidth,
      height: 12.0
    )
    actionLabel.frame = CGRect(
      x: chevronView.frame.minX - 48.0,
      y: 25.0,
      width: 42.0,
      height: 22.0
    )
    let textX = iconView.frame.maxX + 10.0
    let textWidth = max(1.0, actionLabel.frame.minX - textX - 8.0)
    titleLabel.frame = CGRect(x: textX, y: 17.0, width: textWidth, height: 19.0)
    subtitleLabel.frame = CGRect(x: textX, y: 37.0, width: textWidth, height: 18.0)

    if isExpanded {
      dividerView.frame = CGRect(x: 12.0, y: 71.0, width: availableWidth - 24.0, height: 0.5)
      environmentTitleLabel.frame = CGRect(x: 12.0, y: 83.0, width: availableWidth - 24.0, height: 14.0)
      let environmentY: CGFloat = 103.0
      let endpointCount = [pack.eventsURL, pack.invokeURL].compactMap { $0 }.count
      let endpointBlockHeight: CGFloat = endpointCount > 0 ? 30.0 + CGFloat(endpointCount) * 19.0 : 0.0
      let environmentHeight = max(42.0, height - environmentY - endpointBlockHeight - 12.0)
      environmentView.frame = CGRect(
        x: 12.0,
        y: environmentY,
        width: availableWidth - 24.0,
        height: environmentHeight
      )
      copyButton.frame = CGRect(
        x: environmentView.bounds.width - 38.0,
        y: 4.0,
        width: 34.0,
        height: 34.0
      )
      environmentLabel.frame = CGRect(
        x: 10.0,
        y: 10.0,
        width: environmentView.bounds.width - 54.0,
        height: environmentView.bounds.height - 20.0
      )
      if endpointCount > 0 {
        endpointsTitleLabel.frame = CGRect(
          x: 12.0,
          y: environmentView.frame.maxY + 10.0,
          width: availableWidth - 24.0,
          height: 14.0
        )
        endpointsLabel.frame = CGRect(
          x: 12.0,
          y: endpointsTitleLabel.frame.maxY + 4.0,
          width: availableWidth - 24.0,
          height: CGFloat(endpointCount) * 19.0
        )
      }
    }

    accessibilityLabel = "Agent pack for \(identity)"
    accessibilityValue = isExpanded ? "Expanded" : "Collapsed"
    setNeedsLayout()
    return height
  }

  @objc private func handleToggle() {
    guard let pack = currentPack else { return }
    isExpanded.toggle()
    if isExpanded {
      Self.expandedStorageKeys.insert(currentStorageKey)
    } else {
      Self.expandedStorageKeys.remove(currentStorageKey)
    }
    _ = configure(
      pack: pack,
      textColor: currentTextColor,
      availableWidth: currentAvailableWidth,
      storageKey: currentStorageKey
    )
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    NotificationCenter.default.post(name: Notification.Name("AgentCodeBlockExpanded"), object: nil)
    NotificationCenter.default.post(name: .chatNativeStreamingTextLayoutInvalidated, object: self)
  }

  @objc private func handleCopy() {
    guard let pack = currentPack else { return }
    UIPasteboard.general.string = pack.environment
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    !(touch.view is UIControl)
  }
}

// MARK: - AgentCodeBlockView

final class AgentCodeBlockView: UIView {
  private static let collapsedLineLimit = 12
  private static var expandedStorageKeys = Set<String>()

  private let cardView = UIView()
  private let topBarView = UIView()
  private let langLabel = UILabel()
  private let codeLabel = UILabel()
  private let copyButton = UIButton(type: .system)
  private let expandButton = UIButton(type: .system)
  private let copiedLabel = UILabel()
  private var codeContent = ""
  private var codeLang: String?
  private var originalBaseFont = UIFont.systemFont(ofSize: 17.0, weight: .regular)
  private var codeFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  private var baseTextColor = UIColor.white
  private var isExpanded = false
  private let maxCollapsedLines = AgentCodeBlockView.collapsedLineLimit
  private var totalLineCount = 0
  private var copyFeedbackWork: DispatchWorkItem?
  private var currentAvailableWidth: CGFloat = 0
  private var expansionStorageKey = ""

  static func storageKey(code: String, language: String? = nil, override: String? = nil) -> String {
    let trimmedOverride = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedOverride.isEmpty {
      return trimmedOverride
    }
    return (language ?? "") + "\n" + code
  }

  static func isExpanded(code: String, language: String? = nil, storageKey: String? = nil) -> Bool {
    expandedStorageKeys.contains(Self.storageKey(code: code, language: language, override: storageKey))
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    cardView.layer.cornerRadius = 10.0
    cardView.layer.cornerCurve = .continuous
    cardView.clipsToBounds = true
    addSubview(cardView)

    topBarView.backgroundColor = UIColor(white: 0.5, alpha: 0.06)
    cardView.addSubview(topBarView)

    langLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
    langLabel.textColor = UIColor(white: 0.65, alpha: 0.9)
    topBarView.addSubview(langLabel)

    codeLabel.numberOfLines = 0
    codeLabel.backgroundColor = .clear
    cardView.addSubview(codeLabel)

    let cfg = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .medium)
    copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: cfg), for: .normal)
    copyButton.tintColor = UIColor(white: 0.65, alpha: 0.9)
    copyButton.addTarget(self, action: #selector(handleCopy), for: .touchUpInside)
    topBarView.addSubview(copyButton)

    expandButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: cfg), for: .normal)
    expandButton.tintColor = UIColor(white: 0.65, alpha: 0.9)
    expandButton.addTarget(self, action: #selector(handleExpand), for: .touchUpInside)
    topBarView.addSubview(expandButton)

    copiedLabel.text = "Copied!"
    copiedLabel.font = .systemFont(ofSize: 11.0, weight: .medium)
    copiedLabel.textColor = UIColor.systemGreen
    copiedLabel.alpha = 0
    topBarView.addSubview(copiedLabel)
  }

  required init?(coder: NSCoder) { return nil }

  @discardableResult
  func configure(
    code: String,
    language: String? = nil,
    textColor: UIColor,
    baseFont: UIFont,
    availableWidth: CGFloat,
    storageKey: String? = nil
  ) -> CGFloat {
    codeContent = code
    codeLang = language
    baseTextColor = textColor
    currentAvailableWidth = availableWidth
    originalBaseFont = baseFont
    expansionStorageKey = Self.storageKey(code: code, language: language, override: storageKey)
    isExpanded = Self.expandedStorageKeys.contains(expansionStorageKey)
    codeFont = UIFont.monospacedSystemFont(ofSize: max(12.5, baseFont.pointSize - 2.5), weight: .regular)

    let outerH: CGFloat = 0.0
    let hPad: CGFloat = 12.0
    let vPad: CGFloat = 10.0
    let barH: CGFloat = 32.0
    let btnW: CGFloat = 30.0
    let cardWidth = max(1.0, availableWidth - outerH * 2)
    let labelWidth = max(1.0, cardWidth - hPad * 2)

    // Language label
    langLabel.text = language?.lowercased()
    langLabel.isHidden = language == nil

    // Count total lines
    totalLineCount = code.components(separatedBy: "\n").count

    // Determine display text (collapsed vs expanded)
    let displayCode: String
    let needsCollapse = !isExpanded && totalLineCount > maxCollapsedLines
    if needsCollapse {
      displayCode = code.components(separatedBy: "\n").prefix(maxCollapsedLines).joined(separator: "\n")
    } else {
      displayCode = code
    }

    // Plain monospace by default; colorized when expanded
    let attributed: NSAttributedString
    if isExpanded {
      attributed = highlightedCode(displayCode, font: codeFont, baseColor: textColor)
    } else {
      attributed = NSAttributedString(string: displayCode, attributes: [
        .font: codeFont,
        .foregroundColor: textColor.withAlphaComponent(0.88)
      ])
    }
    codeLabel.attributedText = attributed

    let textHeight = ceil(attributed.boundingRect(
      with: CGSize(width: labelWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
    ).height)
    let bodyH = max(ceil(codeFont.lineHeight), textHeight)
    let cardH = barH + vPad + bodyH + vPad

    cardView.backgroundColor = UIColor(white: 0.5, alpha: 0.09)
    cardView.layer.borderWidth = 0.5
    cardView.layer.borderColor = UIColor(white: 0.5, alpha: 0.18).cgColor
    cardView.frame = CGRect(x: outerH, y: 0, width: cardWidth, height: cardH)
    topBarView.frame = CGRect(x: 0, y: 0, width: cardWidth, height: barH)

    // Top bar layout: [langLabel ...  copyBtn  expandBtn]
    langLabel.sizeToFit()
    langLabel.frame = CGRect(x: hPad, y: (barH - langLabel.frame.height) * 0.5,
                             width: langLabel.frame.width, height: langLabel.frame.height)

    expandButton.frame = CGRect(x: cardWidth - btnW - 4.0, y: (barH - btnW) * 0.5, width: btnW, height: btnW)
    copyButton.frame = CGRect(x: expandButton.frame.minX - btnW, y: (barH - btnW) * 0.5, width: btnW, height: btnW)

    copiedLabel.sizeToFit()
    copiedLabel.frame.origin = CGPoint(
      x: copyButton.frame.minX - copiedLabel.frame.width - 6.0,
      y: (barH - copiedLabel.frame.height) * 0.5
    )

    // Update expand icon
    let expandCfg = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .medium)
    let expandIcon = isExpanded
      ? "arrow.down.right.and.arrow.up.left"
      : "arrow.up.left.and.arrow.down.right"
    expandButton.setImage(UIImage(systemName: expandIcon, withConfiguration: expandCfg), for: .normal)
    expandButton.isHidden = totalLineCount <= maxCollapsedLines

    codeLabel.frame = CGRect(x: hPad, y: barH + vPad, width: labelWidth, height: bodyH)
    return outerH + cardH + 8.0
  }

  // MARK: - Syntax highlighting (only used in expanded mode)

  private func highlightedCode(_ code: String, font: UIFont, baseColor: UIColor) -> NSAttributedString {
    let mutable = NSMutableAttributedString(string: code, attributes: [
      .font: font,
      .foregroundColor: baseColor.withAlphaComponent(0.88)
    ])
    let fullRange = NSRange(location: 0, length: (code as NSString).length)

    // Keywords
    let kw = "func|let|var|if|else|for|while|return|class|struct|enum|import|extension|guard|in|where|as|try|catch|throw|switch|case|default|public|private|protocol|static|const|function|new|this|super|await|async|yield|package|interface|implements|override|final|val|def|namespace|using|fn|mut|use|mod|pub|impl|type|trait|match|loop|break|continue|self|Self|nil|null|true|false|None|Some"
    if let re = try? NSRegularExpression(pattern: "\\b(\(kw))\\b") {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor.systemPink, range: m.range)
      }
    }

    // Types / Macros (capitalized words, or word!)
    if let re = try? NSRegularExpression(pattern: "\\b[A-Z][a-zA-Z0-9_]*\\b|\\b[a-z_]+!") {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 1.0), range: m.range)
      }
    }

    // Numbers
    if let re = try? NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b") {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: m.range)
      }
    }

    // Strings
    if let re = try? NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'") {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor.systemGreen, range: m.range)
      }
    }

    // Comments (must be last to override)
    if let re = try? NSRegularExpression(pattern: "//.*|#.*|/\\*[\\s\\S]*?\\*/", options: [.dotMatchesLineSeparators, .anchorsMatchLines]) {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor(white: 0.55, alpha: 1.0), range: m.range)
      }
    }

    return mutable
  }

  @objc private func handleExpand() {
    isExpanded.toggle()
    if isExpanded {
      Self.expandedStorageKeys.insert(expansionStorageKey)
    } else {
      Self.expandedStorageKeys.remove(expansionStorageKey)
    }
    _ = configure(
      code: codeContent,
      language: codeLang,
      textColor: baseTextColor,
      baseFont: originalBaseFont,
      availableWidth: currentAvailableWidth,
      storageKey: expansionStorageKey
    )

    // Trigger parent re-layout
    if let sv = superview {
      sv.setNeedsLayout()
      sv.layoutIfNeeded()
    }
    // Post notification so the table/collection can invalidate its layout
    NotificationCenter.default.post(name: Notification.Name("AgentCodeBlockExpanded"), object: nil)
  }

  @objc private func handleCopy() {
    UIPasteboard.general.string = codeContent
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    copyFeedbackWork?.cancel()
    copiedLabel.alpha = 0
    copyButton.alpha = 0
    UIView.animate(withDuration: 0.15) { self.copiedLabel.alpha = 1.0 }
    let work = DispatchWorkItem { [weak self] in
      UIView.animate(withDuration: 0.25) {
        self?.copiedLabel.alpha = 0
        self?.copyButton.alpha = 1.0
      }
    }
    copyFeedbackWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }
}

extension Notification.Name {
  static let chatNativeStreamingTextLayoutInvalidated = Notification.Name(
    "ChatNativeStreamingTextLayoutInvalidated"
  )
}

private struct ChatNativeStreamingRevealSegment {
  let range: NSRange
  let startTime: CFTimeInterval
  let duration: CFTimeInterval
}

// MARK: - ChatNativeStreamingTextLabel

final class ChatNativeStreamingTextLabel: UITextView {
  private static let streamingFadeAnimationKey = "vibe.streaming.fade"
  private static let streamingChunkFadeDuration: CFTimeInterval = 0.42
  private static let streamingFinalFadeDuration: CFTimeInterval = 0.24
  private static let streamingRevealInitialAlpha: CGFloat = 0.0
  private static let streamingRevealSegmentStagger: CFTimeInterval = 0.0
  private static let streamingRevealSingleSegmentLimit = Int.max
  private static let streamingRevealSegmentMinLength = 44
  private static let streamingRevealSegmentMaxLength = 104

  private var fullAttributedValue: NSAttributedString?
  private var displayedCharacterLength = 0
  private var committedCharacterLength = 0
  private var fadeDisplayLink: CADisplayLink?
  private var revealSegments: [ChatNativeStreamingRevealSegment] = []
  private var lastAppliedStreaming = false
  weak var linkDelegate: ChatNativeStreamingTextLabelDelegate?
  private static let uuidRegex = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}")

  // Compatibility properties for callers using UILabel API
  var numberOfLines: Int {
    get { textContainer.maximumNumberOfLines }
    set { textContainer.maximumNumberOfLines = newValue }
  }

  var targetCharacterLength: Int {
    fullAttributedValue?.length ?? attributedText?.length ?? 0
  }

  var renderedCharacterLength: Int {
    attributedText?.length ?? 0
  }

  var isRevealActiveForMeasurement: Bool {
    fadeDisplayLink != nil
      || !revealSegments.isEmpty
      || displayedCharacterLength < targetCharacterLength
  }

  required init?(coder: NSCoder) {
    return nil
  }

  convenience init() {
    self.init(frame: .zero, textContainer: nil)
  }

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    isEditable = false
    isScrollEnabled = false
    isSelectable = false
    self.textContainerInset = .zero
    self.textContainer.lineFragmentPadding = 0
    self.textContainer.widthTracksTextView = true
    backgroundColor = .clear
    isUserInteractionEnabled = true
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    tap.cancelsTouchesInView = false
    addGestureRecognizer(tap)
  }

  deinit {
    cancelChunkFade()
    stopStreamingFadeAnimation()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      if !revealSegments.isEmpty {
        startStreamingRevealDisplayLinkIfNeeded()
      }
    } else {
      fadeDisplayLink?.invalidate()
      fadeDisplayLink = nil
    }
  }

  func applyStreamingText(_ attributedText: NSAttributedString, rawText: String, isStreaming: Bool) {
    _ = rawText
    let previousTargetText = fullAttributedValue?.string ?? self.attributedText?.string ?? ""
    let previousTargetLength = fullAttributedValue?.length ?? self.attributedText?.length ?? 0
    let currentRenderedString = self.attributedText?.string ?? ""
    let targetString = attributedText.string
    let targetDeltaLength = max(0, attributedText.length - previousTargetLength)

    if currentRenderedString == targetString,
      previousTargetText == targetString,
      isStreaming == lastAppliedStreaming,
      revealSegments.isEmpty
    {
      return
    }

    fullAttributedValue = attributedText
    lastAppliedStreaming = isStreaming

    if !isStreaming {
      if targetString == previousTargetText, !revealSegments.isEmpty {
        displayedCharacterLength = attributedText.length
        startStreamingRevealDisplayLinkIfNeeded()
        return
      }

      if targetString.hasPrefix(previousTargetText),
        targetDeltaLength > 0,
        previousTargetLength > 0
      {
        enqueueAppendedReveal(
          attributedText: attributedText,
          targetString: targetString,
          appendedStart: min(previousTargetLength, attributedText.length)
        )
        return
      }

      cancelChunkFade()
      displayedCharacterLength = attributedText.length
      committedCharacterLength = attributedText.length
      setDisplayedText(
        attributedText,
        animated: previousTargetLength > 0 && targetString != currentRenderedString,
        fadeDuration: Self.streamingFinalFadeDuration
      )
      return
    }

    let shouldResetReveal =
      !previousTargetText.isEmpty
      && !targetString.hasPrefix(previousTargetText)
    let isAppendOnly =
      targetString.hasPrefix(previousTargetText)
      && targetDeltaLength > 0
      && previousTargetLength > 0

    let needsUpdate =
      shouldResetReveal
      || targetDeltaLength > 0
      || (currentRenderedString != targetString && revealSegments.isEmpty)

    guard needsUpdate else {
      if !revealSegments.isEmpty {
        startStreamingRevealDisplayLinkIfNeeded()
      }
      return
    }

    if previousTargetLength == 0, currentRenderedString.isEmpty, attributedText.length > 0 {
      cancelChunkFade()
      displayedCharacterLength = 0
      committedCharacterLength = 0
      enqueueAppendedReveal(
        attributedText: attributedText,
        targetString: targetString,
        appendedStart: 0
      )
      return
    }

    displayedCharacterLength = attributedText.length

    if isAppendOnly && !shouldResetReveal {
      enqueueAppendedReveal(
        attributedText: attributedText,
        targetString: targetString,
        appendedStart: min(previousTargetLength, attributedText.length)
      )
    } else {
      cancelChunkFade()
      committedCharacterLength = attributedText.length
      setDisplayedText(attributedText, animated: false)
    }
  }

  func resetStreamingState() {
    cancelChunkFade()
    stopStreamingFadeAnimation()
    fullAttributedValue = nil
    displayedCharacterLength = 0
    committedCharacterLength = 0
    lastAppliedStreaming = false
    attributedText = nil
  }

  func measurementAttributedText(
    fallback: NSAttributedString,
    isStreaming: Bool
  ) -> (text: NSAttributedString, source: String) {
    _ = isStreaming
    return (fallback, "target")
  }

  private func cancelChunkFade() {
    fadeDisplayLink?.invalidate()
    fadeDisplayLink = nil
    revealSegments.removeAll()
  }

  private func stopStreamingFadeAnimation() {
    layer.removeAnimation(forKey: Self.streamingFadeAnimationKey)
  }

  private func startStreamingRevealDisplayLinkIfNeeded() {
    guard fadeDisplayLink == nil else { return }
    let displayLink = CADisplayLink(target: self, selector: #selector(handleStreamingRevealFrame(_:)))
    displayLink.preferredFramesPerSecond = 60
    displayLink.add(to: .main, forMode: .common)
    fadeDisplayLink = displayLink
  }

  @objc private func handleStreamingRevealFrame(_ displayLink: CADisplayLink) {
    renderStreamingRevealFrame(at: displayLink.timestamp)
  }

  private func enqueueAppendedReveal(
    attributedText: NSAttributedString,
    targetString: String,
    appendedStart: Int
  ) {
    let appendedRange = NSRange(
      location: appendedStart,
      length: max(0, attributedText.length - appendedStart)
    )
    if revealSegments.isEmpty {
      committedCharacterLength = appendedStart
    }
    enqueueRevealSegments(for: appendedRange, in: targetString)
    renderStreamingRevealFrame(at: CACurrentMediaTime(), invalidateLayout: true)
    startStreamingRevealDisplayLinkIfNeeded()
  }

  private func enqueueRevealSegments(for appendedRange: NSRange, in targetString: String) {
    guard appendedRange.length > 0 else { return }
    let now = CACurrentMediaTime()
    let targetNSString = targetString as NSString
    let ranges = revealRanges(in: targetNSString, appendedRange: appendedRange)
    guard !ranges.isEmpty else { return }

    let nextStartTime: CFTimeInterval
    if let latestQueuedStart = revealSegments.map(\.startTime).max() {
      nextStartTime = max(now, latestQueuedStart + Self.streamingRevealSegmentStagger)
    } else {
      nextStartTime = now
    }

    for (index, range) in ranges.enumerated() {
      revealSegments.append(
        ChatNativeStreamingRevealSegment(
          range: range,
          startTime: nextStartTime + CFTimeInterval(index) * Self.streamingRevealSegmentStagger,
          duration: Self.streamingChunkFadeDuration
        )
      )
    }
  }

  private func renderStreamingRevealFrame(
    at timestamp: CFTimeInterval,
    invalidateLayout: Bool = false
  ) {
    guard let target = fullAttributedValue else {
      cancelChunkFade()
      return
    }

    let currentLength = attributedText?.length ?? 0
    let currentString = attributedText?.string ?? ""
    let needsContentUpdate = currentLength != target.length || currentString != target.string
    if needsContentUpdate {
      UIView.performWithoutAnimation {
        self.attributedText = target
      }
      if invalidateLayout {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        notifyLayoutInvalidated()
      }
    }

    guard !revealSegments.isEmpty else {
      displayedCharacterLength = target.length
      committedCharacterLength = target.length
      return
    }

    let storage = textStorage
    let storageRange = NSRange(location: 0, length: storage.length)
    storage.beginEditing()

    var keepers: [ChatNativeStreamingRevealSegment] = []

    for segment in revealSegments {
      let safeRange = NSIntersectionRange(segment.range, storageRange)
      guard safeRange.length > 0 else { continue }

      let rawProgress = CGFloat((timestamp - segment.startTime) / segment.duration)
      let isComplete = rawProgress >= 1.0

      if isComplete {
        applyRevealAlpha(1.0, to: safeRange, from: target, into: storage)
      } else {
        let progress = max(0.0, rawProgress)
        let eased = easedRevealProgress(progress)
        let alphaFactor =
          Self.streamingRevealInitialAlpha
          + (1.0 - Self.streamingRevealInitialAlpha) * eased
        applyRevealAlpha(alphaFactor, to: safeRange, from: target, into: storage)
        keepers.append(segment)
      }
    }

    storage.endEditing()

    revealSegments = keepers
    displayedCharacterLength = target.length

    if keepers.isEmpty {
      fadeDisplayLink?.invalidate()
      fadeDisplayLink = nil
      committedCharacterLength = target.length
    }
  }

  private func revealRanges(in string: NSString, appendedRange: NSRange) -> [NSRange] {
    let availableRange = NSRange(location: 0, length: string.length)
    let safeRange = NSIntersectionRange(appendedRange, availableRange)
    guard safeRange.length > 0 else { return [] }

    if safeRange.length <= Self.streamingRevealSingleSegmentLimit {
      let composedRange = string.rangeOfComposedCharacterSequences(for: safeRange)
      let range = NSIntersectionRange(composedRange, safeRange)
      return range.length > 0 ? [range] : []
    }

    let limit = NSMaxRange(safeRange)
    var cursor = safeRange.location
    var ranges: [NSRange] = []

    while cursor < limit {
      var segmentEnd = cursor
      var lastSoftBoundaryEnd: Int?
      var segmentLength = 0

      while segmentEnd < limit {
        let composedRange = string.rangeOfComposedCharacterSequence(at: segmentEnd)
        let nextEnd = min(NSMaxRange(composedRange), limit)
        let characterRange = NSRange(location: segmentEnd, length: max(0, nextEnd - segmentEnd))
        let character = characterRange.length > 0 ? string.substring(with: characterRange) : ""

        segmentEnd = nextEnd
        segmentLength += characterRange.length

        if isRevealBoundary(character) {
          lastSoftBoundaryEnd = segmentEnd
          if segmentLength >= Self.streamingRevealSegmentMinLength {
            break
          }
        }

        if segmentLength >= Self.streamingRevealSegmentMaxLength {
          if let boundaryEnd = lastSoftBoundaryEnd, boundaryEnd > cursor {
            segmentEnd = boundaryEnd
          }
          break
        }
      }

      let rawRange = NSRange(location: cursor, length: max(1, segmentEnd - cursor))
      let composedRange = string.rangeOfComposedCharacterSequences(for: rawRange)
      let range = NSIntersectionRange(composedRange, safeRange)
      if range.length > 0 {
        ranges.append(range)
      }
      cursor = max(NSMaxRange(composedRange), cursor + 1)
    }

    return ranges
  }

  private func isRevealBoundary(_ character: String) -> Bool {
    guard let scalar = character.unicodeScalars.last else { return false }
    if CharacterSet.whitespacesAndNewlines.contains(scalar) {
      return true
    }
    return ".!,;:?)]}\u{060C}\u{061B}\u{061F}".unicodeScalars.contains(scalar)
  }

  private func easedRevealProgress(_ progress: CGFloat) -> CGFloat {
    progress * progress * (3.0 - 2.0 * progress)
  }

  private func applyRevealAlpha(
    _ alpha: CGFloat,
    to range: NSRange,
    from target: NSAttributedString,
    into storage: NSTextStorage
  ) {
    let storageRange = NSRange(location: 0, length: storage.length)
    let safeRange = NSIntersectionRange(range, storageRange)
    guard safeRange.length > 0 else { return }

    var appliedForeground = false
    target.enumerateAttribute(.foregroundColor, in: safeRange, options: []) { value, subrange, _ in
      let baseColor = (value as? UIColor) ?? self.textColor ?? .label
      let resolved = baseColor.resolvedColor(with: self.traitCollection)
      let baseAlpha = resolved.cgColor.alpha
      storage.addAttribute(
        .foregroundColor,
        value: resolved.withAlphaComponent(baseAlpha * alpha),
        range: subrange
      )
      appliedForeground = true
    }

    if !appliedForeground {
      let resolved = (textColor ?? .label).resolvedColor(with: traitCollection)
      storage.addAttribute(
        .foregroundColor,
        value: resolved.withAlphaComponent(resolved.cgColor.alpha * alpha),
        range: safeRange
      )
    }
  }

  private func setDisplayedText(
    _ attributedText: NSAttributedString,
    animated: Bool,
    fadeDuration: CFTimeInterval = ChatNativeStreamingTextLabel.streamingChunkFadeDuration,
    invalidateLayout: Bool = true
  ) {
    _ = animated
    _ = fadeDuration
    let renderedText = attributedText.length == 0 ? NSAttributedString() : attributedText
    let currentString = self.attributedText?.string ?? ""
    let targetString = renderedText.string
    let textIsIdentical = currentString == targetString

    stopStreamingFadeAnimation()
    UIView.performWithoutAnimation {
      self.attributedText = renderedText
    }
    if invalidateLayout, !textIsIdentical {
      invalidateIntrinsicContentSize()
      setNeedsLayout()
      notifyLayoutInvalidated()
    }
  }

  private func notifyLayoutInvalidated() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil else { return }
      NotificationCenter.default.post(
        name: .chatNativeStreamingTextLayoutInvalidated,
        object: self
      )
    }
  }

  // MARK: - Link tap (layout manager hit-test — no cursor, isSelectable stays false)

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard let attributed = attributedText, attributed.length > 0 else { return }
    let point = gesture.location(in: self)
    let adjusted = CGPoint(
      x: point.x - textContainerInset.left,
      y: point.y - textContainerInset.top
    )
    let charIdx = layoutManager.characterIndex(
      for: adjusted, in: textContainer,
      fractionOfDistanceBetweenInsertionPoints: nil
    )
    guard charIdx < attributed.length else { return }
    let attrs = attributed.attributes(at: charIdx, effectiveRange: nil)
    if let linkVal = attrs[.link] {
      var url: URL?
      if let u = linkVal as? URL { url = u }
      else if let s = linkVal as? String { url = URL(string: s) }
      if let url {
        linkDelegate?.streamingTextLabel(self, didTap: url)
        handleTappedURL(url)
      }
    }
  }

  private func handleTappedURL(_ url: URL) {
    // If link looks like an internal Vibe chat URL, post a notification to let
    // the app route to the chat; otherwise present an in-app browser modal.
    if let chatId = extractChatId(from: url) {
      NotificationCenter.default.post(
        name: Notification.Name("ChatNative.OpenChat"),
        object: nil,
        userInfo: ["chatId": chatId, "url": url.absoluteString]
      )
      return
    }

    DispatchQueue.main.async {
      InAppBrowserViewController.present(url: url)
    }
  }

  private func extractChatId(from url: URL) -> String? {
    // Heuristic: host contains vibe / vibegram and a UUID appears in the path or query
    let host = url.host?.lowercased() ?? ""
    if host.contains("vibe") || host.contains("vibegram") || url.scheme == "vibe" {
      let path = url.path
      let ns = path as NSString
      let range = NSRange(location: 0, length: ns.length)
      if let m = Self.uuidRegex.firstMatch(in: path, range: range) {
        return (ns.substring(with: m.range) as String)
      }
      if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = comps.queryItems {
        for item in items {
          if (item.name.lowercased().contains("chat") || item.name.lowercased().contains("id")), let v = item.value, !v.isEmpty {
            return v
          }
        }
      }
    }
    return nil
  }
}
