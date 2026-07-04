import UIKit

/// Full-page agent workspace: a single soft-blur container that fills the screen
/// (the screen itself never scrolls). Inside it, top-to-bottom:
///   header  — live agent status stream (what the agent is doing right now)
///   body    — real-time code surface: current file (name header + streaming
///             code) with previously-touched files stacked behind it as a
///             receding 3D deck
///   footer  — terminal: the latest commands the agent is running
/// No boxy bordered panels — sections are organized by spacing and type only.
final class VibeAgentWorkspaceView: UIView {
  private var appearance: VibeAgentKitChatAppearance = .fallback
  private var lastConfigurationKey = ""

  private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let containerStack = UIStackView()

  // Header
  private let liveDot = UIView()
  private let statusTitleLabel = UILabel()
  private let statusDetailLabel = UILabel()

  // Body — file deck
  private let deckContainer = UIView()
  private var deckCards: [UIView] = []
  private let fileNameLabel = UILabel()
  private let fileMetaLabel = UILabel()
  private let codeScrollView = UIScrollView()
  private let codeLabel = UILabel()
  private var activeCard: UIView?

  // Footer — terminal
  private let terminalPromptLabel = UILabel()
  private let terminalScrollView = UIScrollView()
  private let terminalLabel = UILabel()

  private var lastFileKey = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) { nil }

  func applyAppearance(_ appearance: VibeAgentKitChatAppearance) {
    self.appearance = appearance
    backgroundColor = appearance.background
    blurView.effect = UIBlurEffect(style: appearance.isDark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight)
    statusTitleLabel.textColor = appearance.text
    statusDetailLabel.textColor = appearance.textSecondary
    fileNameLabel.textColor = appearance.text
    fileMetaLabel.textColor = appearance.textTertiary
    terminalPromptLabel.textColor = appearance.primary
    terminalLabel.textColor = appearance.textSecondary
    lastConfigurationKey = ""
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

    let agentMessages = messages.filter { !$0.role.isUser }
    let items = agentMessages.flatMap(\.progressItems)
    let latestRuntime = agentMessages.reversed().compactMap(\.runtime).first
    let live = agentMessages.contains { $0.isStreaming || $0.runtime?.status == "running" }

    updateHeader(
      items: items,
      live: live,
      provider: provider,
      modelTitle: modelTitle,
      deviceLabel: deviceLabel,
      deviceConnected: deviceConnected,
      isHistoryPicked: isHistoryPicked,
      isLoading: isLoading
    )
    updateFileDeck(items: items, runtime: latestRuntime, live: live)
    updateTerminal(items: items, runtime: latestRuntime)
  }

  // MARK: - Layout

  private func setup() {
    backgroundColor = appearance.background

    blurView.translatesAutoresizingMaskIntoConstraints = false
    blurView.layer.cornerRadius = 24
    blurView.layer.cornerCurve = .continuous
    blurView.clipsToBounds = true
    addSubview(blurView)

    containerStack.translatesAutoresizingMaskIntoConstraints = false
    containerStack.axis = .vertical
    containerStack.spacing = 14
    containerStack.isLayoutMarginsRelativeArrangement = true
    containerStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: 18, leading: 18, bottom: 16, trailing: 18)
    blurView.contentView.addSubview(containerStack)

    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      blurView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),

      containerStack.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
      containerStack.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
      containerStack.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),
      containerStack.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor),
    ])

    setupHeader()
    setupFileDeck()
    setupTerminal()
  }

  private func setupHeader() {
    liveDot.translatesAutoresizingMaskIntoConstraints = false
    liveDot.layer.cornerRadius = 4
    NSLayoutConstraint.activate([
      liveDot.widthAnchor.constraint(equalToConstant: 8),
      liveDot.heightAnchor.constraint(equalToConstant: 8),
    ])

    statusTitleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
    statusTitleLabel.numberOfLines = 1
    statusDetailLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .regular)
    statusDetailLabel.numberOfLines = 1

    let titleRow = UIStackView(arrangedSubviews: [liveDot, statusTitleLabel])
    titleRow.axis = .horizontal
    titleRow.alignment = .center
    titleRow.spacing = 8

    let header = UIStackView(arrangedSubviews: [titleRow, statusDetailLabel])
    header.axis = .vertical
    header.spacing = 3
    containerStack.addArrangedSubview(header)
  }

  private func setupFileDeck() {
    deckContainer.translatesAutoresizingMaskIntoConstraints = false
    containerStack.addArrangedSubview(deckContainer)

    fileNameLabel.font = UIFont.monospacedSystemFont(ofSize: 13.5, weight: .semibold)
    fileNameLabel.numberOfLines = 1
    fileNameLabel.lineBreakMode = .byTruncatingMiddle
    fileMetaLabel.font = UIFont.systemFont(ofSize: 11.5, weight: .medium)
    fileMetaLabel.numberOfLines = 1

    let fileHeader = UIStackView(arrangedSubviews: [fileNameLabel, fileMetaLabel])
    fileHeader.axis = .vertical
    fileHeader.spacing = 2

    codeScrollView.translatesAutoresizingMaskIntoConstraints = false
    codeScrollView.showsVerticalScrollIndicator = false
    codeScrollView.alwaysBounceVertical = false

    codeLabel.translatesAutoresizingMaskIntoConstraints = false
    codeLabel.numberOfLines = 0
    codeLabel.font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    codeScrollView.addSubview(codeLabel)

    let card = UIStackView(arrangedSubviews: [fileHeader, codeScrollView])
    card.axis = .vertical
    card.spacing = 8
    card.isLayoutMarginsRelativeArrangement = true
    card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = UIColor.white.withAlphaComponent(0.045)
    card.layer.cornerRadius = 18
    card.layer.cornerCurve = .continuous
    card.clipsToBounds = true
    deckContainer.addSubview(card)
    activeCard = card

    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: deckContainer.leadingAnchor),
      card.trailingAnchor.constraint(equalTo: deckContainer.trailingAnchor),
      card.bottomAnchor.constraint(equalTo: deckContainer.bottomAnchor),
      // Leave headroom above the active card for the receding stacked cards.
      card.topAnchor.constraint(equalTo: deckContainer.topAnchor, constant: 26),

      codeLabel.topAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.topAnchor),
      codeLabel.leadingAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.leadingAnchor),
      codeLabel.trailingAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.trailingAnchor),
      codeLabel.bottomAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.bottomAnchor),
      codeLabel.widthAnchor.constraint(equalTo: codeScrollView.frameLayoutGuide.widthAnchor),
    ])
    // Body takes all leftover height between header and terminal.
    codeScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
    codeScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
  }

  private func setupTerminal() {
    terminalPromptLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    terminalPromptLabel.numberOfLines = 1
    terminalPromptLabel.lineBreakMode = .byTruncatingMiddle

    terminalScrollView.translatesAutoresizingMaskIntoConstraints = false
    terminalScrollView.showsVerticalScrollIndicator = false

    terminalLabel.translatesAutoresizingMaskIntoConstraints = false
    terminalLabel.numberOfLines = 0
    terminalLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    terminalScrollView.addSubview(terminalLabel)

    let terminal = UIStackView(arrangedSubviews: [terminalPromptLabel, terminalScrollView])
    terminal.axis = .vertical
    terminal.spacing = 6
    terminal.isLayoutMarginsRelativeArrangement = true
    terminal.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
    terminal.backgroundColor = UIColor.black.withAlphaComponent(0.28)
    terminal.layer.cornerRadius = 16
    terminal.layer.cornerCurve = .continuous
    terminal.clipsToBounds = true
    containerStack.addArrangedSubview(terminal)

    NSLayoutConstraint.activate([
      terminal.heightAnchor.constraint(equalToConstant: 118),

      terminalLabel.topAnchor.constraint(equalTo: terminalScrollView.contentLayoutGuide.topAnchor),
      terminalLabel.leadingAnchor.constraint(equalTo: terminalScrollView.contentLayoutGuide.leadingAnchor),
      terminalLabel.trailingAnchor.constraint(equalTo: terminalScrollView.contentLayoutGuide.trailingAnchor),
      terminalLabel.bottomAnchor.constraint(equalTo: terminalScrollView.contentLayoutGuide.bottomAnchor),
      terminalLabel.widthAnchor.constraint(equalTo: terminalScrollView.frameLayoutGuide.widthAnchor),
    ])
  }

  // MARK: - Header content

  private func updateHeader(
    items: [VibeAgentKitProgressItem],
    live: Bool,
    provider: String,
    modelTitle: String,
    deviceLabel: String?,
    deviceConnected: Bool,
    isHistoryPicked: Bool,
    isLoading: Bool
  ) {
    liveDot.backgroundColor = live ? successColor : appearance.textTertiary
    if live {
      liveDot.layer.removeAllAnimations()
      UIView.animate(
        withDuration: 0.9, delay: 0, options: [.autoreverse, .repeat, .allowUserInteraction]
      ) { self.liveDot.alpha = 0.25 }
    } else {
      liveDot.layer.removeAllAnimations()
      liveDot.alpha = 1
    }

    let title: String
    if isLoading {
      title = "Loading run"
    } else if live {
      title = headline(for: items.last)
    } else if isHistoryPicked || !items.isEmpty {
      title = "Run complete"
    } else {
      title = "Ready for a task"
    }
    statusTitleLabel.text = title

    let device = deviceLabel?.isEmpty == false ? deviceLabel! : "Computer"
    statusDetailLabel.text =
      "\(provider.capitalized) · \(modelTitle) · \(device)\(deviceConnected ? "" : " (offline)")"
  }

  private func headline(for item: VibeAgentKitProgressItem?) -> String {
    guard let item else { return "Working" }
    let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
    if !label.isEmpty { return Self.clipped(label, limit: 60) }
    let raw = [item.itemType, item.tool, item.command].compactMap { $0?.lowercased() }.joined(separator: " ")
    if raw.contains("edit") || raw.contains("write") || raw.contains("patch") { return "Editing" }
    if raw.contains("bash") || raw.contains("command") || raw.contains("shell") { return "Running a command" }
    if raw.contains("read") || raw.contains("search") || raw.contains("grep") { return "Reading" }
    if raw.contains("think") || raw.contains("plan") { return "Thinking" }
    return "Working"
  }

  // MARK: - File deck

  private func updateFileDeck(
    items: [VibeAgentKitProgressItem],
    runtime: ChatListRow.AgentRuntimeSummary?,
    live: Bool
  ) {
    let fileItems = items.filter {
      ($0.fileName?.isEmpty == false)
        && (($0.patch?.isEmpty == false) || ($0.fileContent?.isEmpty == false))
    }
    let current = fileItems.last
    let currentName = current?.fileName ?? runtime?.diff?.files.first?.path

    // Receding stack: distinct earlier files, newest closest to the active card.
    var previousNames: [String] = []
    if let currentName {
      var seen = Set([currentName])
      for item in fileItems.reversed() {
        guard let name = item.fileName, !seen.contains(name) else { continue }
        seen.insert(name)
        previousNames.append(name)
        if previousNames.count == 3 { break }
      }
    }
    rebuildDeckCards(previousNames: previousNames)

    guard let currentName else {
      fileNameLabel.text = "No file yet"
      fileMetaLabel.text = live ? "Waiting for the agent to open a file" : "Files will appear here during a run"
      codeLabel.attributedText = nil
      return
    }

    let fileKey = "\(currentName)#\(current?.nodeId ?? "")"
    let fileChanged = fileKey != lastFileKey
    lastFileKey = fileKey

    fileNameLabel.text = (currentName as NSString).lastPathComponent
    var meta: [String] = []
    let directory = (currentName as NSString).deletingLastPathComponent
    if !directory.isEmpty { meta.append(directory) }
    if let tool = current?.itemType ?? current?.tool, !tool.isEmpty { meta.append(tool.capitalized) }
    if let start = current?.lineStart, let end = current?.lineEnd { meta.append("L\(start)–\(end)") }
    fileMetaLabel.text = meta.joined(separator: " · ")

    let code = current?.patch ?? current?.fileContent ?? runtime?.diff?.patch ?? ""
    codeLabel.attributedText = attributedCode(code)

    if fileChanged, let activeCard, activeCard.window != nil {
      // New file slides in from below the deck.
      activeCard.transform = CGAffineTransform(translationX: 0, y: 18).scaledBy(x: 0.97, y: 0.97)
      activeCard.alpha = 0.6
      UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4) {
        activeCard.transform = .identity
        activeCard.alpha = 1
      }
    }

    // Follow the stream: keep the tail of the code in view while live.
    if live {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        let bottom = max(0, self.codeScrollView.contentSize.height - self.codeScrollView.bounds.height)
        self.codeScrollView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
      }
    }
  }

  private func rebuildDeckCards(previousNames: [String]) {
    deckCards.forEach { $0.removeFromSuperview() }
    deckCards = []
    guard let activeCard else { return }

    for (index, name) in previousNames.enumerated() {
      let card = UIView()
      card.translatesAutoresizingMaskIntoConstraints = false
      card.backgroundColor = UIColor.white.withAlphaComponent(0.03)
      card.layer.cornerRadius = 18
      card.layer.cornerCurve = .continuous

      let title = UILabel()
      title.translatesAutoresizingMaskIntoConstraints = false
      title.text = (name as NSString).lastPathComponent
      title.font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
      title.textColor = appearance.textTertiary
      title.lineBreakMode = .byTruncatingMiddle
      card.addSubview(title)

      deckContainer.insertSubview(card, belowSubview: activeCard)
      deckCards.append(card)

      let depth = CGFloat(index + 1)
      let inset = depth * 10
      NSLayoutConstraint.activate([
        card.leadingAnchor.constraint(equalTo: deckContainer.leadingAnchor, constant: inset),
        card.trailingAnchor.constraint(equalTo: deckContainer.trailingAnchor, constant: -inset),
        card.topAnchor.constraint(equalTo: deckContainer.topAnchor, constant: 26 - depth * 9),
        card.heightAnchor.constraint(equalToConstant: 34),

        title.centerYAnchor.constraint(equalTo: card.topAnchor, constant: 15),
        title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
        title.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -14),
      ])

      // Receding 3D tilt: each layer back leans slightly away and fades.
      var transform = CATransform3DIdentity
      transform.m34 = -1.0 / 600.0
      transform = CATransform3DRotate(transform, 0.16, 1, 0, 0)
      transform = CATransform3DScale(transform, 1 - depth * 0.03, 1 - depth * 0.03, 1)
      card.layer.transform = transform
      card.alpha = max(0.25, 0.7 - depth * 0.18)
    }
  }

  // MARK: - Terminal

  private func updateTerminal(
    items: [VibeAgentKitProgressItem],
    runtime: ChatListRow.AgentRuntimeSummary?
  ) {
    let commands = items.filter { item in
      if item.command?.isEmpty == false { return true }
      let raw = [item.itemType, item.tool, item.label].compactMap { $0?.lowercased() }.joined(separator: " ")
      return raw.contains("bash") || raw.contains("command") || raw.contains("shell")
    }
    let latest = commands.last
    let promptCommand = latest?.command ?? runtime?.command?.display

    if let promptCommand, !promptCommand.isEmpty {
      terminalPromptLabel.text = "$ \(Self.clipped(promptCommand, limit: 90))"
    } else {
      terminalPromptLabel.text = "$"
    }

    var lines: [String] = []
    for item in commands.suffix(4) {
      if let command = item.command, !command.isEmpty { lines.append("$ \(command)") }
      if let output = item.messageContent, !output.isEmpty {
        lines.append(Self.clipped(output, limit: 400))
      } else if let status = item.status, !status.isEmpty {
        lines.append(status)
      }
    }
    if lines.isEmpty {
      if let exit = runtime?.exitStatus {
        lines.append(exit == 0 ? "exit 0" : "exit \(exit)")
      } else {
        lines.append("No commands yet.")
      }
    }
    terminalLabel.text = lines.joined(separator: "\n")

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let bottom = max(0, self.terminalScrollView.contentSize.height - self.terminalScrollView.bounds.height)
      self.terminalScrollView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    }
  }

  // MARK: - Code rendering

  private func attributedCode(_ text: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    for (index, line) in text.components(separatedBy: .newlines).enumerated() {
      let color: UIColor
      if line.hasPrefix("+") && !line.hasPrefix("+++") {
        color = successColor
      } else if line.hasPrefix("-") && !line.hasPrefix("---") {
        color = dangerColor
      } else if line.hasPrefix("@@") {
        color = appearance.primary
      } else {
        color = appearance.textSecondary
      }
      if index > 0 { result.append(NSAttributedString(string: "\n")) }
      result.append(
        NSAttributedString(string: line, attributes: [.foregroundColor: color, .font: font])
      )
    }
    return result
  }

  // MARK: - Change detection

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
    var parts: [String] = []
    parts.reserveCapacity(9)
    parts.append(message.id)
    parts.append(message.role.rawValue)
    parts.append(message.isStreaming ? "1" : "0")
    parts.append(message.isError ? "1" : "0")
    parts.append(runtime?.status ?? "")
    parts.append(runtime?.exitStatus.map(String.init) ?? "")
    parts.append(diff.map { "\($0.filesChanged)+\($0.additions)-\($0.deletions)" } ?? "")
    parts.append(String(message.text.prefix(120)))
    parts.append(progressKey)
    return parts.joined(separator: "#")
  }

  private static func progressConfigurationKey(_ item: VibeAgentKitProgressItem) -> String {
    let patchTail: String = item.patch.map { String($0.suffix(160)) } ?? ""
    let contentTail: String = item.fileContent.map { String($0.suffix(160)) } ?? ""
    let messageTail: String = item.messageContent.map { String($0.suffix(120)) } ?? ""
    var parts: [String] = []
    parts.reserveCapacity(8)
    parts.append(item.nodeId ?? "")
    parts.append(item.label)
    parts.append(item.status ?? "")
    parts.append(item.command ?? "")
    parts.append(item.fileName ?? "")
    parts.append(patchTail)
    parts.append(contentTail)
    parts.append(messageTail)
    return parts.joined(separator: ":")
  }

  private static func clipped(_ text: String, limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    return String(trimmed.prefix(limit)) + "..."
  }

  private var successColor: UIColor {
    UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
  }

  private var dangerColor: UIColor {
    UIColor(red: 1.0, green: 0.27, blue: 0.27, alpha: 1.0)
  }
}
