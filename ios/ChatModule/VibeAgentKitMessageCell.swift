import UIKit

final class VibeAgentKitMessageActionBarView: UIView {
  private let buttonSize: CGFloat = 26.0
  private let buttonSpacing: CGFloat = 8.0
  private let copyButton = UIButton(type: .system)
  private let thumbUpButton = UIButton(type: .system)
  private let thumbDownButton = UIButton(type: .system)
  private let regenerateButton = UIButton(type: .system)

  var onAction: ((VibeAgentKitMessageAction) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let visibleButtons = [copyButton, thumbUpButton, thumbDownButton, regenerateButton].filter {
      !$0.isHidden
    }
    let y = max(0.0, (bounds.height - buttonSize) * 0.5)
    var cursorX: CGFloat = 0.0
    for button in visibleButtons {
      button.frame = CGRect(x: cursorX, y: y, width: buttonSize, height: buttonSize)
      cursorX += buttonSize + buttonSpacing
    }
  }

  override var intrinsicContentSize: CGSize {
    let visibleButtons = [copyButton, thumbUpButton, thumbDownButton, regenerateButton].filter {
      !$0.isHidden
    }
    let width = visibleButtons.isEmpty
      ? 0.0
      : (CGFloat(visibleButtons.count) * buttonSize)
        + (CGFloat(max(visibleButtons.count - 1, 0)) * buttonSpacing)
    return CGSize(width: width, height: buttonSize)
  }

  func configure(
    appearance: VibeAgentKitChatAppearance,
    hasSourceText: Bool,
    canRegenerate: Bool
  ) {
    let tint = vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.66 : 0.58)
    applyIcon(.document, to: copyButton, tint: tint)
    applyIcon(.thumbUp, to: thumbUpButton, tint: tint)
    applyIcon(.thumbDown, to: thumbDownButton, tint: tint)
    applyIcon(.refresh, to: regenerateButton, tint: tint)

    [copyButton, thumbUpButton, thumbDownButton, regenerateButton].forEach {
      $0.tintColor = tint
      $0.backgroundColor = .clear
    }

    copyButton.isHidden = !hasSourceText
    thumbUpButton.isHidden = !hasSourceText
    thumbDownButton.isHidden = !hasSourceText
    regenerateButton.isHidden = !canRegenerate
    isHidden = [copyButton, thumbUpButton, thumbDownButton, regenerateButton].allSatisfy(\.isHidden)
    invalidateIntrinsicContentSize()
  }

  private func setup() {
    backgroundColor = .clear
    semanticContentAttribute = .forceLeftToRight
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)

    configureButton(copyButton, action: .copy)
    configureButton(thumbUpButton, action: .thumbUp)
    configureButton(thumbDownButton, action: .thumbDown)
    configureButton(regenerateButton, action: .regenerate)
  }

  private func configureButton(_ button: UIButton, action: VibeAgentKitMessageAction) {
    button.contentHorizontalAlignment = .center
    button.contentVerticalAlignment = .center
    button.semanticContentAttribute = .forceLeftToRight
    var buttonConfiguration = UIButton.Configuration.plain()
    buttonConfiguration.contentInsets = NSDirectionalEdgeInsets(
      top: 4.0,
      leading: 4.0,
      bottom: 4.0,
      trailing: 4.0
    )
    button.configuration = buttonConfiguration
    button.accessibilityIdentifier = "\(action)"
    button.addAction(
      UIAction { [weak self] _ in
        self?.onAction?(action)
      },
      for: .touchUpInside
    )
    addSubview(button)
  }

  private func applyIcon(
    _ kind: VibeAgentKitChatVectorIcon.Kind,
    to button: UIButton,
    tint: UIColor
  ) {
    var configuration = button.configuration ?? UIButton.Configuration.plain()
    configuration.image = VibeAgentKitChatVectorIcon.image(kind, color: tint, size: 17.0)
    button.configuration = configuration
  }
}

private final class VibeAgentKitAssistantMessageBodyView: UIView {
  private let stackView = UIStackView()
  private let loaderView = VibeAgentKitAgentLoaderView()
  // Inline, expandable step list that drops in directly under the "Worked · N
  // steps" line when the user taps it (Claude-Code style) — no separate sheet.
  private let stepsStack = UIStackView()
  private let runtimeSummaryView = AgentRuntimeSummaryView()
  private var blockViews: [UIView] = []
  private var blockHeightConstraints: [NSLayoutConstraint] = []
  private var runtimeHeightConstraint: NSLayoutConstraint?
  private var lastBlockSignature: String = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func prepareForInterfaceBuilder() {
    super.prepareForInterfaceBuilder()
    stackView.layoutIfNeeded()
  }

  func reset() {
    loaderView.configure(text: "", isStreaming: false, progressItems: [])
    loaderView.onTap = nil
    loaderView.isHidden = true
    clearStepsList()
    runtimeSummaryView.onTap = nil
    runtimeSummaryView.isHidden = true
    runtimeHeightConstraint?.constant = 0.0
    removeBlockViews()
  }

  private func clearStepsList() {
    stepsStack.arrangedSubviews.forEach {
      stepsStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    stepsStack.isHidden = true
  }

  // Build the inline step rows shown when "Worked · N steps" is expanded. Each
  // row is a muted, wrapping label with a hanging bullet (matching the body
  // renderer's list style), so the feed reads as a quiet sub-list under the
  // summary line rather than a heavy card.
  private func updateStepsList(
    _ items: [VibeAgentKitProgressItem],
    expanded: Bool,
    appearance: VibeAgentKitChatAppearance
  ) {
    clearStepsList()
    guard expanded, !items.isEmpty else { return }
    let stepFont = UIFont.systemFont(ofSize: 15.0, weight: .regular)
    let marker = "•  "
    let indent = (marker as NSString).size(withAttributes: [.font: stepFont]).width
    let color = appearance.textSecondary
    for item in items {
      let label = UILabel()
      label.numberOfLines = 0
      label.translatesAutoresizingMaskIntoConstraints = false
      let para = NSMutableParagraphStyle()
      para.lineBreakMode = .byWordWrapping
      para.headIndent = indent
      para.lineSpacing = 1.0
      label.attributedText = NSAttributedString(
        string: marker + item.label,
        attributes: [.font: stepFont, .foregroundColor: color, .paragraphStyle: para]
      )
      stepsStack.addArrangedSubview(label)
    }
    stepsStack.isHidden = false
  }

  private func removeBlockViews() {
    for view in blockViews {
      if let label = view as? VibeAgentKitStreamingTextLabel {
        label.resetStreamingState()
      }
      stackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    blockViews.removeAll()
    blockHeightConstraints.removeAll()
    lastBlockSignature = ""
  }

  func configure(
    text: String,
    isStreaming: Bool,
    hasFinalResponseText: Bool,
    appearance: VibeAgentKitChatAppearance,
    availableWidth: CGFloat,
    messageId: String,
    progressItems: [VibeAgentKitProgressItem],
    fallbackProgressLabels: [String],
    runtime: ChatListRow.AgentRuntimeSummary?,
    onRuntimeTap: ((ChatListRow.AgentRuntimeSummary) -> Void)?,
    onLoaderTap: (() -> Void)?,
    isProgressExpanded: Bool = false
  ) {
    let font = UIFont.systemFont(ofSize: 18.0, weight: .regular)
    let lineHeight: CGFloat = 27.5
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasDisplayText = !trimmedText.isEmpty
    let showsLoader = isStreaming && !hasFinalResponseText

    loaderView.applyAppearance(appearance)
    loaderView.onTap = onLoaderTap

    let hasProgressItems = !progressItems.isEmpty
    let shouldShowLoader = showsLoader || hasProgressItems
    // Only a finished turn can expand its step list inline; a live turn shows the
    // shimmer, not a static list.
    let stepsExpanded = isProgressExpanded && hasProgressItems && !showsLoader

    if shouldShowLoader {
      let loaderText: String
      if showsLoader {
        // Live turn: shimmer the action in flight ("Edit chat.ex", "Run …").
        loaderText = progressItems.last?.label ?? fallbackProgressLabels.last ?? "Thinking"
      } else {
        // Completed turn: collapse the whole run into one tappable summary line
        // ("Worked for 1m 3s · N steps") that expands the step list inline. The
        // elapsed time rides the decrypted runtime (live turns carry durationMs);
        // history turns have no duration, so they read "Worked · N steps". Same
        // structure for Claude and Codex — both feed progressItems + runtime.
        loaderText = Self.workedSummary(
          stepCount: progressItems.count,
          durationMs: runtime?.durationMs
        )
      }
      loaderView.isHidden = false
      loaderView.configure(
        text: loaderText,
        isStreaming: showsLoader,
        progressItems: progressItems,
        isExpanded: stepsExpanded
      )
    } else {
      loaderView.isHidden = true
      loaderView.configure(text: "", isStreaming: false, progressItems: [])
    }

    updateStepsList(progressItems, expanded: stepsExpanded, appearance: appearance)

    configureRuntimeSummary(
      runtime,
      textColor: appearance.text,
      availableWidth: availableWidth,
      onTap: onRuntimeTap
    )

    guard hasDisplayText else {
      for (index, view) in blockViews.enumerated() {
        if let label = view as? VibeAgentKitStreamingTextLabel {
          label.resetStreamingState()
        }
        view.isHidden = true
        blockHeightConstraints[index].constant = 0.0
      }
      // No answer text (pure-tool / live-start turn): the summary sits at the top.
      positionSummaryViews(belowText: false)
      return
    }

    let blocks = VibeAgentKitTextRenderer.parseBlocks(text)
    let signature = blocks.map { block -> String in
      switch block {
      case .text:
        return "T"
      case .code:
        return "C"
      }
    }.joined()

    if signature != lastBlockSignature || blockViews.count != blocks.count {
      removeBlockViews()
      for block in blocks {
        let view: UIView
        switch block {
        case .text:
          let label = VibeAgentKitStreamingTextLabel()
          label.translatesAutoresizingMaskIntoConstraints = false
          label.numberOfLines = 0
          label.backgroundColor = .clear
          view = label
        case .code:
          let codeView = VibeAgentKitCodeBlockView()
          codeView.translatesAutoresizingMaskIntoConstraints = false
          view = codeView
        }
        // Insert text blocks above the bottom runtime card. Final ordering of the
        // loader/steps summary (top while live, footer once done) is applied by
        // positionSummaryViews() after this loop.
        stackView.insertArrangedSubview(
          view,
          at: max(1, stackView.arrangedSubviews.count - 1)
        )
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 0.0)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
        blockViews.append(view)
        blockHeightConstraints.append(heightConstraint)
      }
      lastBlockSignature = signature
    }

    var lastTextIndex: Int?
    for (index, block) in blocks.enumerated() {
      if case .text = block {
        lastTextIndex = index
      }
    }

    for (index, block) in blocks.enumerated() {
      let view = blockViews[index]
      view.isHidden = false
      switch block {
      case .text(let content):
        let label = view as! VibeAgentKitStreamingTextLabel
        let attributed = VibeAgentKitTextRenderer.makeAttributedText(
          text: content,
          font: font,
          textColor: appearance.text,
          lineHeight: lineHeight
        )
        let measured = VibeAgentKitTextRenderer.measuredSize(for: attributed, width: availableWidth)
        let height = max(ceil(font.lineHeight), measured.height)
        label.applyStreamingText(
          attributed,
          rawText: content,
          isStreaming: isStreaming && index == lastTextIndex
        )
        blockHeightConstraints[index].constant = height

      case .code(let code, let language):
        let codeView = view as! VibeAgentKitCodeBlockView
        let height = codeView.configure(
          code: code,
          language: language,
          textColor: appearance.text,
          baseFont: font,
          availableWidth: availableWidth,
          storageKey: "\(messageId)#\(index)"
        )
        blockHeightConstraints[index].constant = height
      }
    }

    // A completed turn's "Worked · N steps" summary reads as a footer UNDER the
    // answer (the work is done — show it after, not mid-turn). A live turn keeps
    // the shimmer pinned at the top so you watch it work.
    positionSummaryViews(belowText: shouldShowLoader && !showsLoader)
  }

  /// Place the loader (Worked summary) + its expandable step list either at the TOP
  /// (live turn — watch it work) or as a footer just above the bottom file-change
  /// card (completed turn — the summary follows the answer, Claude-Code style). The
  /// `runtimeSummaryView` always stays last.
  private func positionSummaryViews(belowText: Bool) {
    guard stackView.arrangedSubviews.contains(runtimeSummaryView) else { return }
    if belowText {
      for view in [loaderView, stepsStack] {
        stackView.removeArrangedSubview(view)
        stackView.insertArrangedSubview(view, at: max(0, stackView.arrangedSubviews.count - 1))
      }
    } else {
      stackView.removeArrangedSubview(loaderView)
      stackView.insertArrangedSubview(loaderView, at: 0)
      stackView.removeArrangedSubview(stepsStack)
      stackView.insertArrangedSubview(stepsStack, at: 1)
    }
  }

  // Completed-turn summary line. Matches the Claude Code / Codex "Worked for Xs"
  // affordance: elapsed time first (when the runtime carries it), then the step
  // count. Provider-agnostic — Claude and Codex both populate progressItems and
  // (for live turns) a runtime with durationMs.
  static func workedSummary(stepCount: Int, durationMs: Int?) -> String {
    let steps = max(0, stepCount)
    let stepText = steps == 1 ? "1 step" : "\(steps) steps"
    guard let ms = durationMs, ms >= 1000 else {
      return "Worked · \(stepText)"
    }
    return "Worked for \(formatElapsed(ms)) · \(stepText)"
  }

  private static func formatElapsed(_ ms: Int) -> String {
    let totalSeconds = ms / 1000
    if totalSeconds < 60 { return "\(totalSeconds)s" }
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    if minutes < 60 {
      return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }
    let hours = minutes / 60
    let remMinutes = minutes % 60
    return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
  }

  private func setup() {
    backgroundColor = .clear
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.alignment = .fill
    stackView.distribution = .fill
    stackView.spacing = 7.0
    loaderView.translatesAutoresizingMaskIntoConstraints = false
    loaderView.isHidden = true
    stepsStack.translatesAutoresizingMaskIntoConstraints = false
    stepsStack.axis = .vertical
    stepsStack.alignment = .fill
    stepsStack.distribution = .fill
    stepsStack.spacing = 4.0
    stepsStack.isHidden = true
    stepsStack.isLayoutMarginsRelativeArrangement = true
    stepsStack.layoutMargins = UIEdgeInsets(top: 1.0, left: 4.0, bottom: 3.0, right: 0.0)
    runtimeSummaryView.translatesAutoresizingMaskIntoConstraints = false
    runtimeSummaryView.isHidden = true
    addSubview(stackView)
    // Order: loader ("Worked …"), inline steps (expand target), response text
    // blocks (inserted between here and the runtime card), then the diff card.
    stackView.addArrangedSubview(loaderView)
    stackView.addArrangedSubview(stepsStack)
    stackView.addArrangedSubview(runtimeSummaryView)
    let runtimeHeightConstraint = runtimeSummaryView.heightAnchor.constraint(equalToConstant: 0.0)
    runtimeHeightConstraint.priority = .defaultHigh
    runtimeHeightConstraint.isActive = true
    self.runtimeHeightConstraint = runtimeHeightConstraint

    NSLayoutConstraint.activate([
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private func configureRuntimeSummary(
    _ runtime: ChatListRow.AgentRuntimeSummary?,
    textColor: UIColor,
    availableWidth: CGFloat,
    onTap: ((ChatListRow.AgentRuntimeSummary) -> Void)?
  ) {
    guard let runtime else {
      NSLog("[AgentView] cell.configureRuntimeSummary: runtime=nil -> card HIDDEN")
      runtimeSummaryView.onTap = nil
      runtimeSummaryView.isHidden = true
      runtimeHeightConstraint?.constant = 0.0
      return
    }
    runtimeSummaryView.onTap = onTap
    let height = runtimeSummaryView.configure(
      runtime: runtime,
      textColor: textColor,
      availableWidth: availableWidth
    )
    NSLog("[AgentView] cell.configureRuntimeSummary: card SHOWN files=\(runtime.diff?.files.count ?? -1) +\(runtime.diff?.additions ?? -1)/-\(runtime.diff?.deletions ?? -1) patchLen=\(runtime.diff?.patch?.count ?? -1) height=\(height) width=\(availableWidth)")
    runtimeSummaryView.isHidden = false
    runtimeHeightConstraint?.constant = height
  }
}

private func resoloAssistantDisplayText(for message: VibeAgentKitChatMessage) -> String {
  let finalText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
  let initialText = message.hasInitialResponseText
    ? message.initialResponseText?.trimmingCharacters(in: .whitespacesAndNewlines)
    : nil

  if message.hasFinalResponseText, !finalText.isEmpty {
    return finalText
  }

  guard let initialText, !initialText.isEmpty else {
    return message.text
  }

  guard !finalText.isEmpty else {
    return initialText
  }

  if finalText.hasPrefix(initialText) {
    return finalText
  }

  return "\(initialText)\n\n\(finalText)"
}

final class VibeAgentKitMessageCell: UITableViewCell {
  static let reuseIdentifier = "VibeAgentKitMessageCell"

  private let rowContainer = UIView()
  private let messageContainerView = UIView()
  private let userTextView = VibeAgentKitStreamingTextLabel()
  private let assistantBodyView = VibeAgentKitAssistantMessageBodyView()
  private let progressStack = UIStackView()
  private let actionBar = VibeAgentKitMessageActionBarView()

  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var assistantMaxWidthConstraint: NSLayoutConstraint!
  private var userMaxWidthConstraint: NSLayoutConstraint!
  private var userTopConstraint: NSLayoutConstraint!
  private var userLeadingConstraint: NSLayoutConstraint!
  private var userTrailingConstraint: NSLayoutConstraint!
  private var userBottomConstraint: NSLayoutConstraint!
  private var userTextHeightConstraint: NSLayoutConstraint!
  private var assistantTopConstraint: NSLayoutConstraint!
  private var assistantLeadingConstraint: NSLayoutConstraint!
  private var assistantTrailingConstraint: NSLayoutConstraint!
  private var assistantBottomConstraint: NSLayoutConstraint!
  private var actionBarHeightConstraint: NSLayoutConstraint!
  private var actionBarTopToProgressConstraint: NSLayoutConstraint!
  private var actionBarTopToMessageConstraint: NSLayoutConstraint!
  private var rowTopConstraint: NSLayoutConstraint!
  private var rowBottomConstraint: NSLayoutConstraint!
  private var currentIsUser = false
  private var storedMessageText: String = ""

  var onAction: ((VibeAgentKitMessageAction) -> Void)? {
    didSet {
      actionBar.onAction = onAction
    }
  }

  var onProgressTap: (() -> Void)?
  var onRuntimeTap: ((ChatListRow.AgentRuntimeSummary) -> Void)?

  /// The visible text currently displayed (exposed for the hold context menu).
  var currentMessageText: String { storedMessageText }

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    setup()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onAction = nil
    transform = .identity
    alpha = 1.0
    userTextView.resetStreamingState()
    assistantBodyView.reset()
    onProgressTap = nil
    onRuntimeTap = nil
    progressStack.arrangedSubviews.forEach {
      progressStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    messageContainerView.layer.shadowOpacity = 0.0
    messageContainerView.layer.shadowRadius = 0.0
    messageContainerView.layer.shadowOffset = .zero
    messageContainerView.layer.mask = nil
    currentIsUser = false
    storedMessageText = ""
    // Restore bubble transform / anchor in case the cell is reused while held
    setBubbleHeld(false, animated: false)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    applyCurrentBubbleShape()
  }

  func configure(
    message: VibeAgentKitChatMessage,
    appearance: VibeAgentKitChatAppearance,
    regeneratePrompt: String,
    showsActions: Bool = true,
    isProgressExpanded: Bool = false
  ) {
    let isUser = message.role.isUser
    currentIsUser = isUser
    let displayText = isUser ? message.text : resoloAssistantDisplayText(for: message)
    storedMessageText = displayText

    NSLayoutConstraint.deactivate([
      leadingConstraint,
      trailingConstraint,
      assistantMaxWidthConstraint,
      userMaxWidthConstraint,
      userTopConstraint,
      userLeadingConstraint,
      userTrailingConstraint,
      userBottomConstraint,
      userTextHeightConstraint,
      assistantTopConstraint,
      assistantLeadingConstraint,
      assistantTrailingConstraint,
      assistantBottomConstraint,
      actionBarTopToProgressConstraint,
      actionBarTopToMessageConstraint,
    ])

    if isUser {
      NSLayoutConstraint.activate([
        trailingConstraint,
        userMaxWidthConstraint,
        userTopConstraint,
        userLeadingConstraint,
        userTrailingConstraint,
        userBottomConstraint,
        userTextHeightConstraint,
      ])
    } else {
      NSLayoutConstraint.activate([
        leadingConstraint,
        assistantMaxWidthConstraint,
        assistantTopConstraint,
        assistantLeadingConstraint,
        assistantTrailingConstraint,
        assistantBottomConstraint,
      ])
    }

    rowTopConstraint.constant = isUser ? 4.0 : 3.0
    rowBottomConstraint.constant = isUser ? -4.0 : -3.0

    userTextView.isHidden = !isUser
    assistantBodyView.isHidden = isUser

    progressStack.arrangedSubviews.forEach {
      progressStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }

    if isUser {
      let attributed = VibeAgentKitTextRenderer.makeAttributedText(
        text: displayText,
        font: UIFont.systemFont(ofSize: 18.0, weight: .regular),
        textColor: userBubbleTextColor(for: appearance),
        lineHeight: 27.5
      )
      let fallbackWidth = window?.bounds.width ?? 390.0
      let userWidth = max(
        140.0,
        (contentView.bounds.width > 0.0 ? contentView.bounds.width : fallbackWidth) * 0.68
      )
      let measured = VibeAgentKitTextRenderer.measuredSize(for: attributed, width: userWidth - 32.0)
      userTextHeightConstraint.constant = max(ceil(UIFont.systemFont(ofSize: 18.0, weight: .regular).lineHeight), measured.height)
      userTextView.applyStreamingText(attributed, rawText: displayText, isStreaming: false)

      messageContainerView.backgroundColor = userBubbleColor(for: appearance)
      messageContainerView.layer.cornerRadius = 20.0
      messageContainerView.layer.cornerCurve = .continuous
      messageContainerView.layer.maskedCorners = [
        .layerMaxXMinYCorner,
        .layerMinXMinYCorner,
        .layerMinXMaxYCorner,
        .layerMaxXMaxYCorner,
      ]
      messageContainerView.layer.borderWidth = 0.0
      messageContainerView.layer.borderColor = UIColor.clear.cgColor
      messageContainerView.layer.shadowOpacity = 0.0
      messageContainerView.layer.shadowRadius = 0.0
      messageContainerView.layer.shadowOffset = .zero
    } else {
      #if DEBUG
      let ageMs = message.timestampMs > 0
        ? Int(Date().timeIntervalSince1970 * 1000.0) - Int(message.timestampMs)
        : -1
      print(
        "[VibeAgentKitMessageCell] assistant display message=\(message.id) age_ms=\(ageMs) raw=\(message.text.count) display=\(displayText.count) initial=\(message.initialResponseText?.count ?? 0) hasInitial=\(message.hasInitialResponseText) hasFinal=\(message.hasFinalResponseText) progress=\(message.progress.count) items=\(message.progressItems.count)"
      )
      #endif
      let fallbackWidth = window?.bounds.width ?? 390.0
      let availableWidth = max(
        160.0,
        ((contentView.bounds.width > 0.0 ? contentView.bounds.width : fallbackWidth) - 48.0) * 0.92
      )
      assistantBodyView.isHidden = false
      assistantBodyView.configure(
        text: displayText,
        isStreaming: message.isStreaming,
        hasFinalResponseText: message.hasFinalResponseText,
        appearance: appearance,
        availableWidth: availableWidth,
        messageId: message.id,
        progressItems: message.progressItems,
        fallbackProgressLabels: message.progress,
        runtime: message.runtime,
        onRuntimeTap: onRuntimeTap,
        onLoaderTap: onProgressTap,
        isProgressExpanded: isProgressExpanded
      )

      messageContainerView.backgroundColor = .clear
      messageContainerView.layer.cornerRadius = 0.0
      messageContainerView.layer.borderWidth = 0.0
      messageContainerView.layer.borderColor = UIColor.clear.cgColor
      messageContainerView.layer.shadowOpacity = 0.0
      messageContainerView.layer.shadowRadius = 0.0
      messageContainerView.layer.shadowOffset = .zero
    }

    let visibleProgress: ArraySlice<String> =
      (!displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.isStreaming)
      ? []
      : message.progress.suffix(3)
    for item in visibleProgress where !item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let label = UILabel()
      label.font = UIFont.systemFont(ofSize: 11.5, weight: .medium)
      label.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.82)
      label.numberOfLines = 0
      label.text = item
      progressStack.addArrangedSubview(label)
    }
    let showsVisibleProgress = !isUser && !visibleProgress.isEmpty && !message.isStreaming
    progressStack.isHidden = !showsVisibleProgress
    NSLayoutConstraint.activate([
      showsVisibleProgress ? actionBarTopToProgressConstraint : actionBarTopToMessageConstraint
    ])

    let hasSourceText = !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let canRegenerate = !regeneratePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let shouldShowActions =
      !isUser
      && showsActions
      && !message.isStreaming
      && !message.isError
      && (hasSourceText || canRegenerate)
    actionBar.configure(
      appearance: appearance,
      hasSourceText: hasSourceText,
      canRegenerate: canRegenerate
    )
    actionBarHeightConstraint.constant = shouldShowActions ? 26.0 : 0.0
    actionBar.isHidden = !shouldShowActions
    setNeedsLayout()
  }

  private func setup() {
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    selectionStyle = .none

    [rowContainer, messageContainerView, userTextView, assistantBodyView, progressStack, actionBar]
      .forEach {
        $0.translatesAutoresizingMaskIntoConstraints = false
      }

    contentView.addSubview(rowContainer)
    rowContainer.addSubview(messageContainerView)
    rowContainer.addSubview(progressStack)
    rowContainer.addSubview(actionBar)
    messageContainerView.addSubview(userTextView)
    messageContainerView.addSubview(assistantBodyView)

    progressStack.axis = .vertical
    progressStack.spacing = 3.0
    progressStack.alignment = .leading

    rowTopConstraint = rowContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6.0)
    rowBottomConstraint = rowContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6.0)
    leadingConstraint = messageContainerView.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor, constant: 8.0)
    trailingConstraint = messageContainerView.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor, constant: -8.0)
    assistantMaxWidthConstraint = messageContainerView.widthAnchor.constraint(
      lessThanOrEqualTo: rowContainer.widthAnchor,
      multiplier: 0.92
    )
    userMaxWidthConstraint = messageContainerView.widthAnchor.constraint(
      lessThanOrEqualTo: rowContainer.widthAnchor,
      multiplier: 0.78
    )

    userTopConstraint = userTextView.topAnchor.constraint(equalTo: messageContainerView.topAnchor, constant: 14.0)
    userLeadingConstraint = userTextView.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor, constant: 16.0)
    userTrailingConstraint = userTextView.trailingAnchor.constraint(equalTo: messageContainerView.trailingAnchor, constant: -16.0)
    userBottomConstraint = userTextView.bottomAnchor.constraint(equalTo: messageContainerView.bottomAnchor, constant: -14.0)
    userTextHeightConstraint = userTextView.heightAnchor.constraint(equalToConstant: 24.0)

    assistantTopConstraint = assistantBodyView.topAnchor.constraint(equalTo: messageContainerView.topAnchor)
    assistantLeadingConstraint = assistantBodyView.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor)
    assistantTrailingConstraint = assistantBodyView.trailingAnchor.constraint(equalTo: messageContainerView.trailingAnchor)
    assistantBottomConstraint = assistantBodyView.bottomAnchor.constraint(equalTo: messageContainerView.bottomAnchor)

    userTextHeightConstraint.priority = .defaultHigh
    actionBarHeightConstraint = actionBar.heightAnchor.constraint(equalToConstant: 0.0)
    actionBarHeightConstraint.priority = .defaultHigh
    actionBarTopToProgressConstraint = actionBar.topAnchor.constraint(equalTo: progressStack.bottomAnchor, constant: 4.0)
    actionBarTopToMessageConstraint = actionBar.topAnchor.constraint(equalTo: messageContainerView.bottomAnchor, constant: 6.0)

    NSLayoutConstraint.activate([
      rowTopConstraint,
      rowContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12.0),
      rowContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12.0),
      rowBottomConstraint,

      messageContainerView.topAnchor.constraint(equalTo: rowContainer.topAnchor),
      userTextHeightConstraint,
      actionBarHeightConstraint,

      progressStack.topAnchor.constraint(equalTo: messageContainerView.bottomAnchor, constant: 4.0),
      progressStack.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor),
      progressStack.trailingAnchor.constraint(equalTo: messageContainerView.trailingAnchor),

      actionBar.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor, constant: 1.0),
      actionBar.trailingAnchor.constraint(lessThanOrEqualTo: messageContainerView.trailingAnchor),
      actionBar.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor),
    ])

    leadingConstraint.isActive = true
    assistantMaxWidthConstraint.isActive = true
    assistantTopConstraint.isActive = true
    assistantLeadingConstraint.isActive = true
    assistantTrailingConstraint.isActive = true
    assistantBottomConstraint.isActive = true
    actionBarTopToMessageConstraint.isActive = true
  }

  private func userBubbleColor(for appearance: VibeAgentKitChatAppearance) -> UIColor {
    appearance.userBubbleBackground
  }

  private func userBubbleTextColor(for appearance: VibeAgentKitChatAppearance) -> UIColor {
    appearance.userBubbleText
  }

  private func userBubbleBorderColor(for appearance: VibeAgentKitChatAppearance) -> UIColor {
    appearance.userBubbleBorder
  }

  private func applyCurrentBubbleShape() {
    if currentIsUser {
      messageContainerView.layer.cornerRadius = 20.0
      messageContainerView.layer.cornerCurve = .continuous
      messageContainerView.layer.maskedCorners = [
        .layerMaxXMinYCorner,
        .layerMinXMinYCorner,
        .layerMinXMaxYCorner,
        .layerMaxXMaxYCorner,
      ]
      messageContainerView.layer.mask = nil
    } else {
      messageContainerView.layer.mask = nil
    }
  }

  // MARK: - Bubble hold / long-press transform (Vibe-style)

  /// Applies a scale-down transform to the bubble container when the user long-presses,
  /// pivoted from the bubble's centre so the bubble doesn't drift.
  func setBubbleHeld(_ held: Bool, animated: Bool) {
    let targetScale: CGFloat = held ? 0.965 : 1.0
    let targetTransform: CGAffineTransform =
      held ? CGAffineTransform(scaleX: targetScale, y: targetScale) : .identity

    // Pivot the scale around the bubble's own centre within contentView
    if held {
      let bubbleCenter = messageContainerView.center
      let parentBounds = messageContainerView.superview?.bounds ?? contentView.bounds
      let anchorX = max(0.0, min(1.0, bubbleCenter.x / max(1.0, parentBounds.width)))
      let anchorY = max(0.0, min(1.0, bubbleCenter.y / max(1.0, parentBounds.height)))
      setAnchorPoint(CGPoint(x: anchorX, y: anchorY), for: messageContainerView)
    }

    if animated {
      if held {
        UIView.animate(
          withDuration: 0.18,
          delay: 0.0,
          options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
          self.messageContainerView.transform = targetTransform
        }
      } else {
        UIView.animate(
          withDuration: 0.24,
          delay: 0.0,
          usingSpringWithDamping: 0.90,
          initialSpringVelocity: 0.0,
          options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
          self.messageContainerView.transform = targetTransform
        } completion: { _ in
          self.setAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: self.messageContainerView)
        }
      }
    } else {
      messageContainerView.transform = targetTransform
      if !held {
        setAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: messageContainerView)
      }
    }
  }

  /// Returns the frame of the bubble container in the cell's own coordinate space.
  func bubbleFrameInSelf() -> CGRect {
    messageContainerView.convert(messageContainerView.bounds, to: self)
  }

  // MARK: - Private helpers

  private func setAnchorPoint(_ anchorPoint: CGPoint, for view: UIView) {
    let oldOrigin = view.frame.origin
    view.layer.anchorPoint = anchorPoint
    let newOrigin = view.frame.origin
    let delta = CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y)
    view.center = CGPoint(x: view.center.x - delta.x, y: view.center.y - delta.y)
  }
}
