# Brief — codex — Real chat cells consume accent + corners (iOS production)

You are a team worker. Read the shared board **first**:
`.vibe/team/appearance-0716-board.md`

The frozen contract names you **consume** (grok owns defining them; they may land
concurrently — code against these exact property names):

```
ChatListAppearance.accent: UIColor
ChatListAppearance.messageCornerRadius: CGFloat   // already in POINTS (not 0…1)
ChatListAppearance.wallpaperScrollGradient: [UIColor]  // you may ignore scroll blend
```

Canonical corner mapping (already applied by the model layer):
`radiusPt = 4 + normalized * 22` → points live on `messageCornerRadius`.

## Objective

Wire **production** chat cells so appearance is real, not decorative:

1. **Accent** drives media/cell chrome: voice **waveform** tint, **play button**,
   media plate / selected accents where cells already paint chrome from appearance.
2. **Message corner radius** from `appearance.messageCornerRadius` drives bubble
   corners (and grouped-message corner masking if the cell already differentiates
   first/middle/last).

Reference screenshots (attached via CLI and/or open with tools):
- `/Users/mohammadshayani/Downloads/Screenshot 2026-07-16 at 14.51.59.png`
- `/Users/mohammadshayani/Downloads/Screenshot 2026-07-16 at 14.54.33.png`

## You OWN (edit ONLY this file)

- `ios/ChatModule/ChatListViewCells.swift`

## How to work

1. Grep this file for hard-coded corner radii on message bubbles, waveform colors,
   play-button tints, and any `systemBlue` / fixed teal used as media accent.
2. Prefer existing appearance plumbing (`applyBubbleChrome`, `configure`, agent
   style helpers). Thread `appearance.accent` and `appearance.messageCornerRadius`
   through those paths — do **not** invent a parallel theming system.
3. Bubble corners: use `appearance.messageCornerRadius` as the primary radius.
   For grouped corners (if present), keep relative masking (e.g. smaller tail
   corners) but scale from that primary radius rather than magic constants.
4. Voice/media: waveform bars, play fill, and media plate accents should use
   `appearance.accent` (with alpha variants) instead of hard-coded blues/teals
   when a `ChatListAppearance` is available. Keep contrast readable on me/them
   bubbles.
5. Additive only — do not rename public cell types or break existing configure
   signatures. If you must add parameters, default them.

## Do NOT

- Touch `ChatListViewAppearance.swift` (grok), `ChatListView.swift`,
  `SettingsView.swift`, `ChatEngine.swift`, server, migrations, or new files.
- Run `xcodebuild`, build/launch the app.
- Commit, push, `git checkout/reset/stash`.
- Rewrite layout architecture or “clean up” unrelated cells. Stay on accent +
  corner consumption for real message chrome.

## Acceptance

- Message bubbles respect `appearance.messageCornerRadius`.
- Voice waveform + play button (and obvious media chrome in the same cell path)
  tint from `appearance.accent`.
- No new public renames; no edits outside your file.
- Append an honest summary to `.vibe/team/appearance-0716-board.md` under
  `### codex — …` listing exact sites changed and any places still hard-coded
  with a reason.
