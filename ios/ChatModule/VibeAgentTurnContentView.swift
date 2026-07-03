import OSLog
import UIKit

private let agentTurnContentLogger = Logger(
  subsystem: "com.mohammadshayani.vibe.native",
  category: "AgentTurn"
)

/// Shape-agnostic host for `VibeAgentKitAssistantMessageBodyView` — the real interleaved
/// step/narration/diff renderer (live feed reuse, expand/collapse, diff card). This wrapper
/// owns exactly one body view and pins it edge-to-edge to itself; sizing/shell (full-page
/// table row vs chat bubble) is entirely the caller's job via ordinary Auto Layout
/// constraints on `self` — the wrapper adds none of its own, so it behaves identically to
/// the `assistantBodyView` it replaces inside `VibeAgentKitMessageCell` (Stage 1) and can
/// be dropped into a bubble shell later (Stage 3) without any internal changes.
final class VibeAgentTurnContentView: UIView {
  let bodyView = VibeAgentKitAssistantMessageBodyView()

  var onStepTap: ((String) -> Void)? {
    get { bodyView.onStepTap }
    set { bodyView.onStepTap = newValue }
  }
  var onOpenSubagent: ((String) -> Void)? {
    get { bodyView.onOpenSubagent }
    set { bodyView.onOpenSubagent = newValue }
  }
  var onToggleRuntimeExpand: (() -> Void)? {
    get { bodyView.onToggleRuntimeExpand }
    set { bodyView.onToggleRuntimeExpand = newValue }
  }
  var onReviewTapped: (() -> Void)? {
    get { bodyView.onReviewTapped }
    set { bodyView.onReviewTapped = newValue }
  }
  var onFileTapped: ((ChatListRow.AgentRuntimeFile) -> Void)? {
    get { bodyView.onFileTapped }
    set { bodyView.onFileTapped = newValue }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    bodyView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(bodyView)
    // The chat-bubble cell positions this wrapper with MANUAL FRAMES (it never turns off
    // translatesAutoresizingMaskIntoConstraints), so the wrapper's frame becomes a REQUIRED
    // autoresizing height constraint — including `height == 0` while parked at `.zero`.
    // If the bottom pin below were also required, any mismatch between that frame height
    // and the body's own required content height (every stream tick, every `.zero` park)
    // is unsatisfiable, and UIKit "recovers" by breaking a random internal stack
    // constraint — collapsing the live feed to nothing (the mid-stream empty-bubble
    // flicker). Priority 999 lets the bottom pin give way silently instead; it still
    // outranks `.fittingSizeLevel`, so `measuredHeight`'s systemLayoutSizeFitting math
    // is unaffected.
    let bottomPin = bodyView.bottomAnchor.constraint(equalTo: bottomAnchor)
    bottomPin.priority = UILayoutPriority(999)
    NSLayoutConstraint.activate([
      bodyView.topAnchor.constraint(equalTo: topAnchor),
      bodyView.leadingAnchor.constraint(equalTo: leadingAnchor),
      bodyView.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottomPin,
    ])
  }

  required init?(coder: NSCoder) { return nil }

  func reset() {
    bodyView.reset()
  }

  /// Straight pass-through to `bodyView.configure(...)`. `availableWidth` must match
  /// whatever width `self` will actually resolve to under the caller's own constraints
  /// (the body view's internal text/step measurement math depends on it) — same contract
  /// `VibeAgentKitMessageCell` already relied on for `assistantBodyView`.
  func configure(
    text: String,
    isStreaming: Bool,
    hasFinalResponseText: Bool,
    appearance: VibeAgentKitChatAppearance,
    availableWidth: CGFloat,
    messageId: String,
    progressItems: [VibeAgentKitProgressItem],
    subagentChildren: [String: [VibeAgentKitProgressItem]] = [:],
    fallbackProgressLabels: [String],
    runtime: ChatListRow.AgentRuntimeSummary?,
    onLoaderTap: (() -> Void)?,
    isProgressExpanded: Bool = false,
    isRuntimeExpanded: Bool = false,
    expandedStepIds: Set<String> = [],
    streamingStartDate: Date? = nil
  ) {
    bodyView.configure(
      text: text,
      isStreaming: isStreaming,
      hasFinalResponseText: hasFinalResponseText,
      appearance: appearance,
      availableWidth: availableWidth,
      messageId: messageId,
      progressItems: progressItems,
      subagentChildren: subagentChildren,
      fallbackProgressLabels: fallbackProgressLabels,
      runtime: runtime,
      onLoaderTap: onLoaderTap,
      isProgressExpanded: isProgressExpanded,
      isRuntimeExpanded: isRuntimeExpanded,
      expandedStepIds: expandedStepIds,
      streamingStartDate: streamingStartDate
    )
  }

  /// Row-based convenience for the chat-bubble cell: builds the `VibeAgentKitChatMessage`
  /// via the same `VibeAgentKitMap` bridge the full-page view uses, so the bubble renders
  /// through an identical data path (no second mapping layer to drift out of sync).
  func configure(
    row: ChatListRow,
    appearance: VibeAgentKitChatAppearance,
    availableWidth: CGFloat,
    isProgressExpanded: Bool,
    isRuntimeExpanded: Bool,
    expandedStepIds: Set<String>,
    streamingStartDate: Date?,
    onLoaderTap: (() -> Void)?
  ) {
    let message = VibeAgentKitMap.chatMessage(from: row)
    var displayText = resoloAssistantDisplayText(for: message)

    // Guard against the "stopped mid-stream → blank bubble" bug: when a turn is
    // FINALIZED (not streaming) but maps to nothing renderable — no answer text, no
    // progress steps, no runtime card — the body view produces zero height and the
    // caller floors the shell to ~44pt, leaving a visible-but-empty bubble even though
    // the message row still exists in the list. This happens when the user hits STOP
    // before any assistant text/tool node was persisted (or the finalize dropped the
    // in-flight nodes). Substitute a minimal "Stopped" placeholder so the turn is never
    // invisible, and log it so we can spot any OTHER path that lands here.
    if !message.isStreaming
      && displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && message.progressItems.isEmpty
      && message.runtime == nil
    {
      let statusText = row.status ?? "nil"
      let kindText = row.agentMsgKind ?? "nil"
      agentTurnContentLogger.notice(
        "EMPTY finalized turn id=\(message.id, privacy: .public) status=\(statusText, privacy: .public) kind=\(kindText, privacy: .public) nodes=\(row.agentProgressNodes.count, privacy: .public) hasRuntime=N -> 'Stopped' placeholder"
      )
      displayText = "Stopped"
    }

    configure(
      text: displayText,
      isStreaming: message.isStreaming,
      hasFinalResponseText: message.hasFinalResponseText,
      appearance: appearance,
      availableWidth: availableWidth,
      messageId: message.id,
      progressItems: message.progressItems,
      subagentChildren: message.subagentChildren,
      fallbackProgressLabels: message.progress,
      runtime: message.runtime,
      onLoaderTap: onLoaderTap,
      isProgressExpanded: isProgressExpanded,
      isRuntimeExpanded: isRuntimeExpanded,
      expandedStepIds: expandedStepIds,
      streamingStartDate: streamingStartDate
    )
  }
}

extension VibeAgentTurnContentView {
  /// Offscreen "sizing template" — ONE shared instance reused across measurement calls
  /// (never added to a window), matching the classic self-sizing-cell trick: avoids
  /// allocating a fresh Auto Layout view graph per row on every layout pass, which
  /// `systemLayoutSizeFitting` would otherwise cost given how often the chat list's
  /// manual sizing pipeline re-measures during a live agent stream.
  private static let sizingTemplate: VibeAgentTurnContentView = {
    let view = VibeAgentTurnContentView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
  private static var sizingWidthConstraint: NSLayoutConstraint?

  /// Height `configure(row:...)` would produce at `availableWidth`, without needing a
  /// live instance in the view hierarchy. Callers should pass the SAME expand-state
  /// values they'll use for the subsequent live `configure(row:...)` call so the
  /// measured height matches what actually renders.
  static func measuredHeight(
    row: ChatListRow,
    appearance: VibeAgentKitChatAppearance,
    availableWidth: CGFloat,
    isProgressExpanded: Bool,
    isRuntimeExpanded: Bool,
    expandedStepIds: Set<String>,
    streamingStartDate: Date?
  ) -> CGFloat {
    let template = sizingTemplate
    // CRITICAL: clear any block / feed / loader views left over from measuring a
    // DIFFERENT row on this shared template. `configure(...)` reuses cached subviews
    // keyed by block-signature and node id, so without a reset the previously-measured
    // (often taller) turn's views linger and inflate THIS row's fitting height. The live
    // cell holds its OWN body-view instance with the real (shorter/empty) content, so the
    // desync renders as a tall-but-empty bubble — and because the leftover state changes
    // per measured row / per stream tick, the measured height swings between huge and the
    // caller's floor. Resetting first makes each measurement reflect only this row.
    template.reset()
    if let constraint = sizingWidthConstraint {
      constraint.constant = availableWidth
    } else {
      let constraint = template.widthAnchor.constraint(equalToConstant: availableWidth)
      constraint.isActive = true
      sizingWidthConstraint = constraint
    }
    template.configure(
      row: row,
      appearance: appearance,
      availableWidth: availableWidth,
      isProgressExpanded: isProgressExpanded,
      isRuntimeExpanded: isRuntimeExpanded,
      expandedStepIds: expandedStepIds,
      streamingStartDate: streamingStartDate,
      onLoaderTap: nil
    )
    // Force a layout pass so intrinsic-size-driven subviews (e.g. the loader, which
    // relies on `intrinsicContentSize`/`sizeThatFits` rather than an explicit height
    // constraint) actually resolve on this offscreen, never-windowed template before we
    // read a fitting size. Without this, a transient streaming state can leave the
    // vertical dimension underconstrained.
    template.setNeedsLayout()
    template.layoutIfNeeded()
    // CRITICAL: target height MUST be finite. `systemLayoutSizeFitting` returns the
    // target-size value verbatim for any dimension that ends up unconstrained (the
    // `.fittingSizeLevel` target constraint is then the only one). If that target were
    // `.greatestFiniteMagnitude`, an underconstrained turn would yield an infinite row
    // height → `UICollectionViewCell` rounding assertion / crash. A finite 0 target
    // collapses to the caller's `max(52, …)` floor instead, and self-corrects on the
    // next stream tick.
    let size = template.systemLayoutSizeFitting(
      CGSize(width: availableWidth, height: 0.0),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    guard size.height.isFinite, size.height > 0.0 else { return 0.0 }
    return ceil(size.height)
  }
}
