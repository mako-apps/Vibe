# Vibe UI/UX Review & Advisory Report (2026-07-15)

Acted by: **Agy (Gemini)**, UI/UX Advisor

This document provides concrete, prioritized UI/UX guidance for the iOS dynamic progress runner contract, the "one runner + per-worker sheet" design pattern, and the web parity goals.

---

## 1. iOS Team Rendering: "One Runner + Per-Worker Sheet"

### A. Layout & Hierarchy
* **Worker Row Typography Hierarchy:** In [VibeAgentKitMessageCell.swift](file:///Users/mohammadshayani/Vibe/ios/ChatModule/VibeAgentKitMessageCell.swift#L1173), the `VibeAgentKitTeamWorkerRowView` displays worker name and status side-by-side. 
  * *Guidance:* Keep a strict typographic hierarchy. The worker name (`nameLabel`) must remain semi-bold (`systemFont(ofSize: 14, weight: .semibold)`) and full opacity, while the status (`statusLabel`) should be smaller (`systemFont(ofSize: 12.5)`) and lower opacity (`appearance.textSecondary` with `0.78` alpha).
* **Distinct Worker Avatars:** Because model names are hidden, the avatar (`SenderRunAvatarView`) is the primary visual anchor for worker identity. 
  * *Guidance:* Style avatar backgrounds with recognizable, brand-matched colors (e.g. Claude orange `#D97706`, Grok dark slate, Codex purple). Do not use generic fallbacks.
* **Status Text Truncation Safety:** Live status texts (e.g. "running build_suite.py") can be long.
  * *Guidance:* Ensure the horizontal layout assigns a minimum of 40% of the bubble's content width to the `statusLabel` before truncating (`lineBreakMode = .byTruncatingTail`). Do not let a long worker name squeeze the status text out of visibility.

### B. Motion & Transitions (Avoiding List-Jump & Jank)
* **Constant Row Heights:** A major source of list-jumping during streams is variable-height rows.
  * *Guidance:* Keep `VibeAgentKitTeamWorkerRowView` locked to a fixed height (e.g. exactly `36pt` including padding). Under no circumstances should the status text wrap onto multiple lines; force single-line truncation.
* **Transitioning States (Spinner vs. Checkmark):** 
  * *Guidance:* When a worker transitions from `running` to `done`, do not instantly swap the spinner and checkmark. Use a subtle fade transition (`0.2s` duration) for `spinner.alpha` and `doneCheck.alpha` to prevent sudden pixel flickering.
* **The "Worked" Transition Collapse:** Toggling between the active stream (multiple worker rows) and the settled state ("Worked Ym" summary + final orchestrator bubble) causes significant layout changes.
  * *Guidance:* When transitioning the cells, use `collectionView.performBatchUpdates` to animate the frame change. Animate the worker rows collapsing vertically using a scale-Y and fade-out transition, while scaling up the "Worked" summary bar.

### C. Done & Loading States
* **Skeleton instead of Spinner:** 
  * *Guidance:* When a subagent sheet is tapped open and the data is loading, use a subtle shimmering skeleton screen (mimicking the shape of code blocks or text rows) instead of a central spinner. A spinner creates visual anxiety, while a skeleton sets spatial expectations.
* **The "Worked" Summary Design:**
  * *Guidance:* The summary cell (e.g., `Worked for 1m 3s · 5 steps`) should have a pill-shaped boundary, styled as a subtle, low-opacity glass card (`backdrop-filter` or thin material on iOS) to differentiate it from normal text message bubbles.

### D. Accessibility
* **Accessible Actions:**
  * *Guidance:* Set the `accessibilityLabel` on `VibeAgentKitTeamWorkerRowView` to format as: `"[Worker Name], status: [Status Text], double tap to open progress details"`.
  * *Guidance:* Set `accessibilityHint` to `"Opens details and patches for this worker."`
* **Live Updates Announcing:**
  * *Guidance:* When a critical worker fails (status: `failed`), post a layout change notification `UIAccessibility.post(notification: .layoutChanged, argument: "Worker [Name] failed")` so screen reader users are immediately alerted.

### E. Pitfalls of the "One Runner + Per-Worker Sheet" Pattern
* **Modal Context Disconnection:** Opening a full-page modal sheet disconnects the user from the wider team's real-time orchestration.
  * *Guidance:* 
    * Add a minimized "global progress bar" at the top of the sheet showing active status of the other workers (e.g. "Grok: done · Claude: running").
    * Support seamless lateral navigation (swipe left/right inside the sheet to switch between worker progress views) instead of forcing the user to close the sheet and tap a different row.
* **Sheet Presentation Churn:** If the sheet is open while the worker is streaming patches, appending text continuously can block the main UI thread.
  * *Guidance:* Throttle sheet updates to `120ms` intervals (similar to `measuredHeight` caching in iOS) to avoid over-rendering.

---

## 2. Web Parity Goals

### A. Authentication Page
* **Premium Aesthetics:**
  * *Guidance:* Avoid standard browser fields. The auth card should use a glassmorphic container (`background: rgba(255, 255, 255, 0.03)`, `backdrop-filter: blur(16px)`, `border: 1px solid rgba(255, 255, 255, 0.08)`).
  * *Guidance:* On focus, input borders should animate with a soft, glowing gradient transition rather than a sudden blue outline.
* **Motion & Transitions:**
  * *Guidance:* Use Framer Motion's `AnimatePresence` to cross-fade and slide between the "Sign In" and "Sign Up" views (using `direction` states matching the view transition pattern in [Chat.tsx](file:///Users/mohammadshayani/Vibe/client/src/components/Chat.tsx#L178)).

### B. Home & Chat-List
* **Swipe-to-Action (Pin/Delete):** 
  * *Guidance:* In [Home.tsx](file:///Users/mohammadshayani/Vibe/client/src/components/Home.tsx#L134), `window.confirm` is used for deleting a chat. Replace this with a custom, premium modal overlay or a non-blocking toast notification with an **"Undo"** action.
  * *Guidance:* The background swipe colors (red/blue) should be muted to match the luxurious Slate/Zinc/Mauve theme palette defined in [PatternWallpaper.tsx](file:///Users/mohammadshayani/Vibe/client/src/components/PatternWallpaper.tsx#L60).
* **Typing Indicator Parity:**
  * *Guidance:* Instead of plain text `typing...`, use three animated bouncing dots with a shimmer effect to match the native iOS feel.

### C. Chat Wallpapers, Gradients, & Themes
* **Low-Contrast Masking:**
  * *Guidance:* The masked SVG pattern in `PatternWallpaper.tsx` is excellent. Keep the stroke opacity extremely low (`0.03` to `0.08` depending on background brightness) to ensure it acts as a background texture and never competes with text legibility.
* **Unified Theme Variables:**
  * *Guidance:* Export theme gradients and colors as CSS variables (`--theme-bg-gradient`, `--theme-bubble-me`) instead of hardcoding values inside React components. This allows real-time theme swapping without triggering React re-renders.

### D. Input Area & Headers
* **Header Deck Glassmorphism:**
  * *Guidance:* The chat header deck should use a heavy blur (`backdrop-filter: blur(24px)`) and a linear-gradient transparent mask (`mask-image`) on its bottom edge so scrolling messages fade out smoothly instead of cutting off abruptly.
* **Input Area:**
  * *Guidance:* The input textarea should resize dynamically up to `5 lines` before scrolling. The send icon button should scale up (`scale: 1.15`) and fade in when text exists, using spring physics rather than linear timing.

---

## 3. Prioritized Implementation Roadmap

1. **[High Priority] iOS List-Jump Mitigation:** Lock the height constraints on `VibeAgentKitTeamWorkerRowView` and disable text wrapping.
2. **[High Priority] Web Custom Swipe Delete:** Remove `window.confirm` from `Home.tsx` and implement a non-blocking custom modal.
3. **[Medium Priority] Sheet Lateral Navigation:** Implement swipe gestures within the worker progress sheet to cycle through worker details without closing the modal.
4. **[Medium Priority] CSS Variables for Themes:** Move hardcoded theme strings in web to CSS custom properties.
5. **[Low Priority] Skeleton Shimmers:** Replace intermediate spinners in sheets with animated skeleton components.
