import UIKit

let listBottomThreshold: CGFloat = 88.0
let messageHorizontalInset: CGFloat = 16.0
let messageSelectionLeadingInset: CGFloat = 38.0
let sectionTopInset: CGFloat = 10.0
let sectionBottomInset: CGFloat = 14.0
let bubbleSideMargin: CGFloat = 8.0
let bubbleHorizontalPadding: CGFloat = 10.0
let bubbleTopPadding: CGFloat = 7.0
let bubbleBottomPadding: CGFloat = 7.0
let bubbleMetaTopSpacing: CGFloat = 2.0
let bubbleMetaHeight: CGFloat = 15.0
let bubbleMinWidth: CGFloat = 26.0
let bubbleMaxWidthFactor: CGFloat = 0.85
// The inline agent-turn bubble packs a rich, already-padded step/narration/diff feed, so
// the surrounding chat-bubble shell wants a tighter inset than a plain text bubble (whose
// content is a bare label) — otherwise the doubled padding reads as too much air.
let agentTurnHorizontalPadding: CGFloat = 6.0
let agentTurnVerticalPadding: CGFloat = 4.0
// Agent turns render wide, information-dense content; give them more of the row than the
// 0.85 a chat bubble uses so steps/diffs aren't cramped.
let agentTurnMaxWidthFactor: CGFloat = 0.92
let dayPillHorizontalPadding: CGFloat = 11.0
let dayPillVerticalPadding: CGFloat = 4.0
