import UIKit

final class VibeAgentWorkspaceView: UIView {
  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private var appearance: VibeAgentKitChatAppearance = .fallback
  private var lastConfigurationKey = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) { nil }

  func applyAppearance(_ appearance: VibeAgentKitChatAppearance) {
    self.appearance = appearance
    backgroundColor = appearance.background
    scrollView.backgroundColor = appearance.background
    rebuildIfPossible(force: true)
  }

  func configure(
    messages: [VibeAgentKitChatMessage],
    provider: String,
    displayTitle: String,
    modelTitle: String,
    deviceLabel: String?,
    deviceConnected: Bool,
    isHistoryPicked: Bool,
    isLoading: Bool
  ) {
    let key = Self.configurationKey(
      messages: messages,
      provider: provider,
      modelTitle: modelTitle,
      deviceLabel: deviceLabel,
      deviceConnected: deviceConnected,
      isHistoryPicked: isHistoryPicked,
      isLoading: isLoading
    )
    guard key != lastConfigurationKey else { return }
    lastConfigurationKey = key
    rebuild(
      messages: messages,
      provider: provider,
      displayTitle: displayTitle,
      modelTitle: modelTitle,
      deviceLabel: deviceLabel,
      deviceConnected: deviceConnected,
      isHistoryPicked: isHistoryPicked,
      isLoading: isLoading
    )
  }

  private func setup() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    scrollView.keyboardDismissMode = .interactive
    addSubview(scrollView)

    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .vertical
    contentStack.spacing = 12
    contentStack.isLayoutMarginsRelativeArrangement = true
    contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: 12, leading: 16, bottom: 18, trailing: 16)
    scrollView.addSubview(contentStack)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
    ])
  }

  private func rebuildIfPossible(force: Bool) {
    guard force, !lastConfigurationKey.isEmpty else { return }
    lastConfigurationKey = ""
  }

  private func rebuild(
    messages: [VibeAgentKitChatMessage],
    provider: String,
    displayTitle: String,
    modelTitle: String,
    deviceLabel: String?,
    deviceConnected: Bool,
    isHistoryPicked: Bool,
    isLoading: Bool
  ) {
    contentStack.removeAllArrangedSubviews()

    let agentMessages = messages.filter { !$0.role.isUser }
    let latestAgent = agentMessages.reversed().first {
      $0.isStreaming
        || !$0.progressItems.isEmpty
        || $0.runtime != nil
        || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let latestUser = messages.reversed().first { $0.role.isUser }
    let allItems = agentMessages.flatMap(\.progressItems)
    let latestRuntime = agentMessages.reversed().compactMap(\.runtime).first
    let live = agentMessages.contains { $0.isStreaming || $0.runtime?.status == "running" }
    let status = workspaceStatus(
      latestAgent: latestAgent,
      latestItem: allItems.last,
      latestRuntime: latestRuntime,
      live: live,
      isHistoryPicked: isHistoryPicked,
      isLoading: isLoading
    )

    contentStack.addArrangedSubview(
      statusPanel(
        title: status.title,
        subtitle: status.subtitle,
        provider: provider,
        modelTitle: modelTitle,
        deviceLabel: deviceLabel,
        deviceConnected: deviceConnected,
        live: live
      )
    )

    if !isHistoryPicked && messages.isEmpty {
      contentStack.addArrangedSubview(
        emptyPanel(displayTitle: displayTitle, modelTitle: modelTitle, deviceLabel: deviceLabel)
      )
      return
    }

    if let latestUser {
      contentStack.addArrangedSubview(promptPanel(latestUser.text))
    }

    contentStack.addArrangedSubview(metricsPanel(items: allItems, runtime: latestRuntime))

    if let fileView = activeFilePanel(items: allItems, runtime: latestRuntime) {
      contentStack.addArrangedSubview(fileView)
    }

    if let problemView = problemsPanel(messages: agentMessages, items: allItems, runtime: latestRuntime) {
      contentStack.addArrangedSubview(problemView)
    }

    if let commandView = commandsPanel(items: allItems, runtime: latestRuntime) {
      contentStack.addArrangedSubview(commandView)
    }

    if let filesView = changedFilesPanel(runtime: latestRuntime) {
      contentStack.addArrangedSubview(filesView)
    }

    if let timelineView = timelinePanel(items: allItems) {
      contentStack.addArrangedSubview(timelineView)
    }
  }

  private static func configurationKey(
    messages: [VibeAgentKitChatMessage],
    provider: String,
    modelTitle: String,
    deviceLabel: String?,
    deviceConnected: Bool,
    isHistoryPicked: Bool,
    isLoading: Bool
  ) -> String {
    let tail = messages.suffix(6).map(messageConfigurationKey).joined(separator: "||")
    return [
      provider,
      modelTitle,
      deviceLabel ?? "",
      deviceConnected ? "1" : "0",
      isHistoryPicked ? "1" : "0",
      isLoading ? "1" : "0",
      tail,
    ].joined(separator: "~~~")
  }

  private static func messageConfigurationKey(_ message: VibeAgentKitChatMessage) -> String {
    let runtime = message.runtime
    let diff = runtime?.diff
    let progressKey = message.progressItems.suffix(8)
      .map(progressConfigurationKey)
      .joined(separator: "|")
    let exitStatus = runtime?.exitStatus.map(String.init) ?? ""
    let filesChanged = diff.map { String($0.filesChanged) } ?? ""
    let additions = diff.map { String($0.additions) } ?? ""
    let deletions = diff.map { String($0.deletions) } ?? ""
    var parts: [String] = []
    parts.reserveCapacity(11)
    parts.append(message.id)
    parts.append(message.role.rawValue)
    parts.append(message.isStreaming ? "1" : "0")
    parts.append(message.isError ? "1" : "0")
    parts.append(String(message.text.prefix(160)))
    parts.append(runtime?.status ?? "")
    parts.append(exitStatus)
    parts.append(filesChanged)
    parts.append(additions)
    parts.append(deletions)
    parts.append(progressKey)
    return parts.joined(separator: "#")
  }

  private static func progressConfigurationKey(_ item: VibeAgentKitProgressItem) -> String {
    var parts: [String] = []
    parts.reserveCapacity(7)
    parts.append(item.nodeId ?? "")
    parts.append(item.label)
    parts.append(item.status ?? "")
    parts.append(item.command ?? "")
    parts.append(item.patch.map { String($0.prefix(120)) } ?? "")
    parts.append(item.fileContent.map { String($0.prefix(120)) } ?? "")
    parts.append(item.messageContent.map { String($0.prefix(120)) } ?? "")
    return parts.joined(separator: ":")
  }

  private func workspaceStatus(
    latestAgent: VibeAgentKitChatMessage?,
    latestItem: VibeAgentKitProgressItem?,
    latestRuntime: ChatListRow.AgentRuntimeSummary?,
    live: Bool,
    isHistoryPicked: Bool,
    isLoading: Bool
  ) -> (title: String, subtitle: String) {
    if isLoading {
      return ("Loading workspace", "Pulling the selected run into view")
    }
    if !isHistoryPicked {
      return ("Ready for a task", "The next run will render as files, commands, diffs, and problems")
    }
    if hasProblem(latestAgent: latestAgent, latestRuntime: latestRuntime) {
      return ("Agent hit a problem", "Review the problem panel before continuing")
    }
    if live {
      return ("Agent is \(activeVerb(for: latestItem))", "Live bridge payload is updating this screen")
    }
    if latestRuntime != nil || latestAgent != nil {
      return ("Run complete", "The latest payload is organized below")
    }
    return ("Workspace ready", "Waiting for the first bridge payload")
  }

  private func activeVerb(for item: VibeAgentKitProgressItem?) -> String {
    let raw = [
      item?.itemType,
      item?.tool,
      item?.label,
      item?.command,
    ].compactMap { $0?.lowercased() }.joined(separator: " ")
    if raw.contains("edit") || raw.contains("write") || raw.contains("patch") {
      return "editing"
    }
    if raw.contains("bash") || raw.contains("command") || raw.contains("exec") || raw.contains("shell") {
      return "running a command"
    }
    if raw.contains("read") || raw.contains("search") || raw.contains("grep") || raw.contains("glob") {
      return "reading"
    }
    if raw.contains("think") || raw.contains("plan") || raw.contains("reason") {
      return "thinking"
    }
    return "working"
  }

  private func hasProblem(
    latestAgent: VibeAgentKitChatMessage?,
    latestRuntime: ChatListRow.AgentRuntimeSummary?
  ) -> Bool {
    if latestAgent?.isError == true { return true }
    if let exit = latestRuntime?.exitStatus, exit != 0 { return true }
    let status = latestRuntime?.status.lowercased() ?? ""
    return status.contains("error") || status.contains("fail")
  }

  private func statusPanel(
    title: String,
    subtitle: String,
    provider: String,
    modelTitle: String,
    deviceLabel: String?,
    deviceConnected: Bool,
    live: Bool
  ) -> UIView {
    let titleLabel = label(title, size: 22, weight: .semibold, color: appearance.text, lines: 2)
    let subtitleLabel = label(subtitle, size: 14, weight: .regular, color: appearance.textSecondary, lines: 2)
    let metaStack = UIStackView(arrangedSubviews: [
      pill(provider.capitalized, symbol: "sparkles", tint: appearance.primary),
      pill(modelTitle, symbol: "cpu", tint: appearance.textSecondary),
      pill(deviceLabel?.isEmpty == false ? deviceLabel! : "Computer", symbol: "desktopcomputer",
           tint: deviceConnected ? successColor : warningColor),
    ])
    metaStack.axis = .horizontal
    metaStack.alignment = .leading
    metaStack.spacing = 8
    metaStack.distribution = .fillProportionally

    let stack = panelStack()
    stack.spacing = 10
    stack.addArrangedSubview(liveHeader(titleLabel: titleLabel, live: live))
    stack.addArrangedSubview(subtitleLabel)
    stack.addArrangedSubview(metaStack)
    return stack
  }

  private func emptyPanel(displayTitle: String, modelTitle: String, deviceLabel: String?) -> UIView {
    let stack = panelStack()
    stack.alignment = .center
    stack.spacing = 8
    let icon = UIImageView(image: UIImage(systemName: "rectangle.3.group.bubble.left"))
    icon.tintColor = appearance.primary
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 34),
      icon.heightAnchor.constraint(equalToConstant: 34),
    ])
    stack.addArrangedSubview(icon)
    stack.addArrangedSubview(label(displayTitle, size: 17, weight: .semibold, color: appearance.text, lines: 1))
    stack.addArrangedSubview(
      label(
        "\(modelTitle) is ready on \(deviceLabel?.isEmpty == false ? deviceLabel! : "your computer").",
        size: 14,
        weight: .regular,
        color: appearance.textSecondary,
        lines: 2
      )
    )
    return stack
  }

  private func promptPanel(_ text: String) -> UIView {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return UIView() }
    let stack = sectionPanel(title: "Current request", symbol: "quote.bubble")
    stack.addArrangedSubview(label(Self.clipped(trimmed, limit: 280), size: 14, weight: .regular, color: appearance.text, lines: 5))
    return stack
  }

  private func metricsPanel(items: [VibeAgentKitProgressItem], runtime: ChatListRow.AgentRuntimeSummary?) -> UIView {
    let diff = runtime?.diff
    let commands = commandItems(from: items).count
    let fileCount = diff?.filesChanged ?? diff?.files.count ?? changedFileNames(from: items)
    let metricViews: [UIView] = [
      metric("Files", "\(fileCount)", tint: appearance.primary),
      metric("Added", "+\(diff?.additions ?? addedLines(from: items))", tint: successColor),
      metric("Removed", "-\(diff?.deletions ?? removedLines(from: items))", tint: dangerColor),
      metric("Commands", "\(commands)", tint: appearance.textSecondary),
    ]
    let grid = UIStackView(arrangedSubviews: metricViews)
    grid.axis = .horizontal
    grid.spacing = 8
    grid.distribution = .fillEqually
    return grid
  }

  private func activeFilePanel(
    items: [VibeAgentKitProgressItem],
    runtime: ChatListRow.AgentRuntimeSummary?
  ) -> UIView? {
    let fileItem = items.reversed().first {
      ($0.fileName?.isEmpty == false)
        || ($0.patch?.isEmpty == false)
        || ($0.fileContent?.isEmpty == false)
    }
    let runtimeFile = runtime?.diff?.files.first
    let title = fileItem?.fileName ?? runtimeFile?.path ?? runtimeFile?.name
    guard let title, !title.isEmpty else { return nil }

    let stack = sectionPanel(title: "Active file", symbol: "doc.text.magnifyingglass")
    let meta = activeFileMeta(item: fileItem, runtimeFile: runtimeFile)
    stack.addArrangedSubview(twoLineRow(title: title, subtitle: meta, symbol: "doc.text"))

    let snippet =
      fileItem?.patch
      ?? fileItem?.fileContent
      ?? fileItem?.messageContent
      ?? runtime?.diff?.patch
    if let snippet, !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      stack.addArrangedSubview(codeBlock(snippet, maxLines: 18))
    } else {
      stack.addArrangedSubview(label("Waiting for code payload.", size: 13, weight: .regular, color: appearance.textSecondary, lines: 1))
    }
    return stack
  }

  private func problemsPanel(
    messages: [VibeAgentKitChatMessage],
    items: [VibeAgentKitProgressItem],
    runtime: ChatListRow.AgentRuntimeSummary?
  ) -> UIView? {
    var problems: [(String, String)] = []
    if let exit = runtime?.exitStatus, exit != 0 {
      problems.append(("Command exited with \(exit)", runtime?.command?.display ?? runtime?.status ?? "Run failed"))
    }
    for message in messages where message.isError {
      let body = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
      problems.append(("Agent response failed", body.isEmpty ? "The stream marked this turn as failed." : body))
    }
    for item in items where itemLooksProblem(item) {
      problems.append((item.label, item.messageContent ?? item.status ?? "The bridge marked this step as a problem."))
    }
    guard !problems.isEmpty else { return nil }
    let stack = sectionPanel(title: "Problems", symbol: "exclamationmark.triangle")
    for problem in problems.prefix(4) {
      stack.addArrangedSubview(twoLineRow(title: problem.0, subtitle: Self.clipped(problem.1, limit: 220), symbol: "exclamationmark.circle", tint: dangerColor))
    }
    return stack
  }

  private func commandsPanel(
    items: [VibeAgentKitProgressItem],
    runtime: ChatListRow.AgentRuntimeSummary?
  ) -> UIView? {
    var commands = commandItems(from: items).suffix(5).map { item in
      (
        title: item.command ?? item.label,
        subtitle: item.messageContent ?? item.status ?? "Command"
      )
    }
    if commands.isEmpty, let command = runtime?.command?.display {
      commands.append((title: command, subtitle: runtime?.status ?? "Command"))
    }
    guard !commands.isEmpty else { return nil }
    let stack = sectionPanel(title: "Commands", symbol: "terminal")
    for command in commands {
      stack.addArrangedSubview(twoLineRow(title: command.title, subtitle: Self.clipped(command.subtitle, limit: 180), symbol: "terminal"))
    }
    return stack
  }

  private func changedFilesPanel(runtime: ChatListRow.AgentRuntimeSummary?) -> UIView? {
    guard let files = runtime?.diff?.files, !files.isEmpty else { return nil }
    let stack = sectionPanel(title: "Changed files", symbol: "folder")
    for file in files.prefix(8) {
      let detail = "\(file.status)  +\(file.additions)  -\(file.deletions)"
      stack.addArrangedSubview(twoLineRow(title: file.path, subtitle: detail, symbol: "doc"))
    }
    return stack
  }

  private func timelinePanel(items: [VibeAgentKitProgressItem]) -> UIView? {
    guard !items.isEmpty else { return nil }
    let stack = sectionPanel(title: "Live timeline", symbol: "point.topleft.down.curvedto.point.bottomright.up")
    for item in items.suffix(10) {
      stack.addArrangedSubview(
        twoLineRow(
          title: item.label,
          subtitle: timelineSubtitle(item),
          symbol: symbol(for: item),
          tint: tint(for: item)
        )
      )
    }
    return stack
  }

  private func sectionPanel(title: String, symbol: String) -> UIStackView {
    let stack = panelStack()
    stack.addArrangedSubview(sectionHeader(title: title, symbol: symbol))
    return stack
  }

  private func sectionHeader(title: String, symbol: String) -> UIView {
    let row = UIStackView()
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 8
    let image = UIImageView(image: UIImage(systemName: symbol))
    image.tintColor = appearance.primary
    image.contentMode = .scaleAspectFit
    image.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      image.widthAnchor.constraint(equalToConstant: 18),
      image.heightAnchor.constraint(equalToConstant: 18),
    ])
    row.addArrangedSubview(image)
    row.addArrangedSubview(label(title, size: 15, weight: .semibold, color: appearance.text, lines: 1))
    return row
  }

  private func liveHeader(titleLabel: UILabel, live: Bool) -> UIView {
    let row = UIStackView()
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 10
    let dot = UIView()
    dot.backgroundColor = live ? successColor : appearance.textTertiary
    dot.layer.cornerRadius = 5
    dot.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: 10),
      dot.heightAnchor.constraint(equalToConstant: 10),
    ])
    row.addArrangedSubview(dot)
    row.addArrangedSubview(titleLabel)
    return row
  }

  private func panelStack() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 10
    stack.isLayoutMarginsRelativeArrangement = true
    stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    stack.backgroundColor = appearance.surface
    stack.layer.cornerRadius = 12
    stack.layer.cornerCurve = .continuous
    stack.layer.borderWidth = 0.7
    stack.layer.borderColor = appearance.border.cgColor
    return stack
  }

  private func metric(_ title: String, _ value: String, tint: UIColor) -> UIView {
    let stack = panelStack()
    stack.spacing = 4
    stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
    stack.addArrangedSubview(label(value, size: 20, weight: .semibold, color: tint, lines: 1, alignment: .center))
    stack.addArrangedSubview(label(title, size: 11, weight: .medium, color: appearance.textSecondary, lines: 1, alignment: .center))
    return stack
  }

  private func twoLineRow(
    title: String,
    subtitle: String,
    symbol: String,
    tint: UIColor? = nil
  ) -> UIView {
    let row = UIStackView()
    row.axis = .horizontal
    row.alignment = .top
    row.spacing = 10

    let image = UIImageView(image: UIImage(systemName: symbol))
    image.tintColor = tint ?? appearance.textSecondary
    image.contentMode = .scaleAspectFit
    image.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      image.widthAnchor.constraint(equalToConstant: 18),
      image.heightAnchor.constraint(equalToConstant: 18),
    ])

    let textStack = UIStackView()
    textStack.axis = .vertical
    textStack.spacing = 3
    textStack.addArrangedSubview(label(title, size: 13.5, weight: .semibold, color: appearance.text, lines: 2))
    textStack.addArrangedSubview(label(subtitle, size: 12.5, weight: .regular, color: appearance.textSecondary, lines: 3))

    row.addArrangedSubview(image)
    row.addArrangedSubview(textStack)
    return row
  }

  private func pill(_ text: String, symbol: String, tint: UIColor) -> UIView {
    let row = UIStackView()
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 5
    row.isLayoutMarginsRelativeArrangement = true
    row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 9)
    row.backgroundColor = appearance.surfaceElevated
    row.layer.cornerRadius = 8
    row.layer.cornerCurve = .continuous

    let image = UIImageView(image: UIImage(systemName: symbol))
    image.tintColor = tint
    image.contentMode = .scaleAspectFit
    image.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      image.widthAnchor.constraint(equalToConstant: 13),
      image.heightAnchor.constraint(equalToConstant: 13),
    ])
    row.addArrangedSubview(image)
    row.addArrangedSubview(label(text, size: 11.5, weight: .medium, color: appearance.textSecondary, lines: 1))
    return row
  }

  private func codeBlock(_ text: String, maxLines: Int) -> UIView {
    let label = UILabel()
    label.numberOfLines = 0
    label.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    label.attributedText = attributedCode(text, maxLines: maxLines)

    let wrapper = UIView()
    wrapper.backgroundColor = appearance.isDark
      ? UIColor(red: 0.055, green: 0.055, blue: 0.06, alpha: 1.0)
      : UIColor(red: 0.965, green: 0.962, blue: 0.955, alpha: 1.0)
    wrapper.layer.cornerRadius = 10
    wrapper.layer.cornerCurve = .continuous
    wrapper.layer.borderWidth = 0.6
    wrapper.layer.borderColor = appearance.border.cgColor

    label.translatesAutoresizingMaskIntoConstraints = false
    wrapper.addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 10),
      label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 10),
      label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -10),
      label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -10),
    ])
    return wrapper
  }

  private func attributedCode(_ text: String, maxLines: Int) -> NSAttributedString {
    var lines = text.components(separatedBy: .newlines)
    let clipped = lines.count > maxLines
    if clipped {
      lines = Array(lines.prefix(maxLines))
      lines.append("...")
    }

    let result = NSMutableAttributedString()
    for (index, line) in lines.enumerated() {
      let color: UIColor
      if line.hasPrefix("+") {
        color = successColor
      } else if line.hasPrefix("-") {
        color = dangerColor
      } else if line.hasPrefix("@@") {
        color = appearance.primary
      } else {
        color = appearance.textSecondary
      }
      if index > 0 { result.append(NSAttributedString(string: "\n")) }
      result.append(
        NSAttributedString(
          string: line,
          attributes: [
            .foregroundColor: color,
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
          ]
        )
      )
    }
    return result
  }

  private func label(
    _ text: String,
    size: CGFloat,
    weight: UIFont.Weight,
    color: UIColor,
    lines: Int,
    alignment: NSTextAlignment = .left
  ) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = UIFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.numberOfLines = lines
    label.textAlignment = alignment
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  private func activeFileMeta(
    item: VibeAgentKitProgressItem?,
    runtimeFile: ChatListRow.AgentRuntimeFile?
  ) -> String {
    if let item {
      var parts: [String] = []
      if let tool = item.itemType ?? item.tool, !tool.isEmpty { parts.append(tool.capitalized) }
      if let start = item.lineStart, let end = item.lineEnd { parts.append("Lines \(start)-\(end)") }
      if let status = item.status, !status.isEmpty { parts.append(status.capitalized) }
      return parts.isEmpty ? item.label : parts.joined(separator: " - ")
    }
    if let runtimeFile {
      return "\(runtimeFile.status)  +\(runtimeFile.additions)  -\(runtimeFile.deletions)"
    }
    return "File payload"
  }

  private func timelineSubtitle(_ item: VibeAgentKitProgressItem) -> String {
    var parts: [String] = []
    if let status = item.status, !status.isEmpty { parts.append(status.capitalized) }
    if let file = item.fileName, !file.isEmpty { parts.append(file) }
    if let command = item.command, !command.isEmpty { parts.append(command) }
    if let content = item.messageContent, !content.isEmpty { parts.append(Self.clipped(content, limit: 120)) }
    return parts.isEmpty ? (item.itemType ?? item.tool ?? "Step") : parts.joined(separator: " - ")
  }

  private func commandItems(from items: [VibeAgentKitProgressItem]) -> [VibeAgentKitProgressItem] {
    items.filter { item in
      if item.command?.isEmpty == false { return true }
      let raw = [item.itemType, item.tool, item.label].compactMap { $0?.lowercased() }.joined(separator: " ")
      return raw.contains("bash") || raw.contains("command") || raw.contains("shell")
    }
  }

  private func itemLooksProblem(_ item: VibeAgentKitProgressItem) -> Bool {
    let raw = [item.status, item.messageContent, item.label]
      .compactMap { $0?.lowercased() }
      .joined(separator: " ")
    return raw.contains("error")
      || raw.contains("failed")
      || raw.contains("exception")
      || raw.contains("traceback")
      || raw.contains("cannot")
      || raw.contains("not found")
  }

  private func symbol(for item: VibeAgentKitProgressItem) -> String {
    let raw = [item.itemType, item.tool, item.label].compactMap { $0?.lowercased() }.joined(separator: " ")
    if itemLooksProblem(item) { return "exclamationmark.triangle" }
    if raw.contains("bash") || raw.contains("command") { return "terminal" }
    if raw.contains("edit") || raw.contains("write") || raw.contains("patch") { return "pencil" }
    if raw.contains("read") { return "doc.text.magnifyingglass" }
    if raw.contains("search") || raw.contains("grep") || raw.contains("glob") { return "magnifyingglass" }
    if raw.contains("think") || raw.contains("plan") { return "lightbulb" }
    return "circle"
  }

  private func tint(for item: VibeAgentKitProgressItem) -> UIColor {
    if itemLooksProblem(item) { return dangerColor }
    let raw = [item.itemType, item.tool, item.label].compactMap { $0?.lowercased() }.joined(separator: " ")
    if raw.contains("edit") || raw.contains("write") || raw.contains("patch") { return appearance.primary }
    if raw.contains("bash") || raw.contains("command") { return warningColor }
    return appearance.textSecondary
  }

  private func changedFileNames(from items: [VibeAgentKitProgressItem]) -> Int {
    Set(items.compactMap { $0.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).count
  }

  private func addedLines(from items: [VibeAgentKitProgressItem]) -> Int {
    items.reduce(0) { total, item in
      total + (item.patch?.components(separatedBy: .newlines).filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count ?? 0)
    }
  }

  private func removedLines(from items: [VibeAgentKitProgressItem]) -> Int {
    items.reduce(0) { total, item in
      total + (item.patch?.components(separatedBy: .newlines).filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count ?? 0)
    }
  }

  private static func clipped(_ text: String, limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    return String(trimmed.prefix(limit)) + "..."
  }

  private var successColor: UIColor {
    UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
  }

  private var warningColor: UIColor {
    UIColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1.0)
  }

  private var dangerColor: UIColor {
    UIColor(red: 1.0, green: 0.27, blue: 0.27, alpha: 1.0)
  }
}

private extension UIStackView {
  func removeAllArrangedSubviews() {
    for view in arrangedSubviews {
      removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }
}
