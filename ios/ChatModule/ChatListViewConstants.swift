import UIKit

let listBottomThreshold: CGFloat = 88.0
let messageHorizontalInset: CGFloat = 10.0
let messageSelectionLeadingInset: CGFloat = 38.0
let sectionTopInset: CGFloat = 10.0
let sectionBottomInset: CGFloat = 14.0
let bubbleSideMargin: CGFloat = 4.0
let bubbleHorizontalPadding: CGFloat = 12.0
let bubbleTopPadding: CGFloat = 7.0
let bubbleBottomPadding: CGFloat = 7.0
let bubbleMetaTopSpacing: CGFloat = 2.0
let bubbleMetaHeight: CGFloat = 14.0
let bubbleMinWidth: CGFloat = 26.0
let bubbleMaxWidthFactor: CGFloat = 0.85
// The inline agent-turn bubble must read as a NORMAL them-bubble: its answer prose is a
// bare edge-to-edge label inside the body view (no internal leading inset), so the shell
// has to supply the SAME inset a plain text bubble uses or the text hugs the bubble edge
// and looks misaligned against every other incoming message. Keep these equal to the
// plain-bubble constants — do not tighten them (the earlier 6/4 tightening is what made the
// agent text sit ~6pt further left + higher than a real them-bubble).
let agentTurnHorizontalPadding: CGFloat = bubbleHorizontalPadding
let agentTurnVerticalPadding: CGFloat = bubbleTopPadding
// Match the plain-bubble width so an agent turn is the same shape as any other incoming
// message. Rich content (diff cards / step lists) scrolls/wraps inside this width rather
// than widening the whole bubble past its neighbours.
let agentTurnMaxWidthFactor: CGFloat = bubbleMaxWidthFactor
let dayPillHorizontalPadding: CGFloat = 11.0
let dayPillVerticalPadding: CGFloat = 4.0
