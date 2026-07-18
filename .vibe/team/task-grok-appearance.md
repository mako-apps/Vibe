# Brief — grok — Appearance live preview (iOS)

You are a team worker. Read the shared board `.vibe/team/settings-0716-1424-board.md`
and the contract `docs/settings-account-architecture.md` (section "Appearance model")
FIRST.

## Objective

Make the appearance system production-grade with a **live preview**: as the user
adjusts appearance settings, a preview chat surface updates in real time.

## You OWN (edit ONLY this)

- `ios/ChatModule/ChatListViewAppearance.swift`

## Contract (the appearance model — persist/consume these)

- Persisted fields: `mode`, `themeId`, wallpaper kind/value, accent color, a two-stop
  bubble gradient, text scale, message corner scale, animations enabled.
- Views consume **semantic tokens**, not hard-coded theme colors.
- Provide a reusable **preview surface** (a small mock conversation: a couple of
  incoming/outgoing bubbles + wallpaper) that renders from the current appearance
  values and updates live as they change. The integrator will embed this preview into
  the Settings appearance screen — so expose it as a self-contained SwiftUI/UIKit view
  the integrator can drop in.

## Do NOT

- Touch `SettingsView.swift` (the integrator embeds your preview there), any server
  file, or another worker's files.
- Run `xcodebuild` or build/launch the iOS app — you cannot; the integrator builds
  once at the end. Just edit the Swift file.
- Commit, push, or `git checkout/reset/stash`.
- Follow the repo threading rule: never call the chat engine synchronously from the
  main thread (use the existing async patterns in the file).

## Acceptance

- A self-contained preview view exists that renders from appearance values and updates
  live when they change, using semantic tokens.
- No change to public type/function names other code depends on (add, don't rename).
- Append a short summary + the exact name of the preview view the integrator should
  embed to the board's Handoff section.
