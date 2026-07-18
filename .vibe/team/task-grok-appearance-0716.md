# Brief — grok — Appearance contract + pure helpers (iOS)

You are a team worker. Read the shared board **first**:
`.vibe/team/appearance-0716-board.md`

That board has the **FROZEN CONTRACT**. Code against those exact names.

## Objective

Turn the appearance system into a real, production-grade **draft → model** pipeline.
Do **NOT** build a fake/mock chat preview. The live preview is integrator-owned later
(it injects a draft into the real `ChatListView`). You only own the contract types +
pure helpers.

Reference screenshots (open with your image tool if available):
- `/Users/mohammadshayani/Downloads/Screenshot 2026-07-16 at 14.51.59.png`
- `/Users/mohammadshayani/Downloads/Screenshot 2026-07-16 at 14.54.33.png`

## You OWN (edit ONLY this file)

- `ios/ChatModule/ChatListViewAppearance.swift`

## Required deliverables (exact names)

### 1. `ChatAppearanceDraft` — Equatable, Codable

Create this struct exactly as on the board (hex strings, not UIColor):

```
struct ChatAppearanceDraft: Equatable, Codable {
  var version: Int = 1
  var mode: String = "dark"                 // "dark" | "light" | "system"
  var themeId: String? = nil

  var wallpaperKind: String = "gradient"    // "builtin" | "solid" | "gradient" | "custom"
  var wallpaperGradient: [String] = ["#05050B", "#05050B"]
  var wallpaperGradientLocations: [Double] = [0.0, 1.0]
  var wallpaperScrollGradient: [String] = []  // optional 2nd pair for scroll blend
  var wallpaperPatternMaskKey: String? = "doodles"
  var wallpaperPatternOpacity: Double = 0.17

  var bubbleMeGradient: [String] = ["#8B7CFF", "#08C6B4"]
  var bubbleThemGradient: [String] = ["#252936", "#1A202C"]

  var accent: String = "#2F9E93"
  var messageCornerRadius: Double = 0.62    // NORMALIZED 0…1
  var textScale: Double = 1.0
  var animationsEnabled: Bool = true
}
```

Also provide:
- `static let default` / sensible defaults matching Vibe Aurora fallback colors
- `from(raw: [String: Any]?)` and `asDictionary` (or Codable-compatible dict helpers) so the integrator can persist it later

### 2. Extend `ChatListAppearance` with three NEW stored fields

```
let accent: UIColor                    // default: ChatListAppearance.brandAccentFallback
let messageCornerRadius: CGFloat       // default: 18  (== mapping at ~normalized 0.636)
let wallpaperScrollGradient: [UIColor] // default: []  (empty = no scroll blend)
```

**CRITICAL:** existing `ChatListAppearance(...)` call sites (~14 memberwise inits) must
keep compiling. Provide an explicit initializer (or defaulted parameters) so callers
that omit the three new fields still work. Update `static let fallback` and any
`from(raw:)` / preset builders so they set sensible defaults for the new fields.

### 3. Canonical corner mapping (ONE source of truth)

```
// normalized 0…1 → 4pt…26pt
static func messageCornerRadiusPoints(normalized: Double) -> CGFloat {
  CGFloat(4.0 + max(0.0, min(1.0, normalized)) * 22.0)
}
```

Put this on `ChatAppearanceDraft` or `ChatListAppearance` (or a small shared helper in
this same file). Document it in a comment. Do not invent a second mapping.

### 4. `ChatListAppearance.from(draft: ChatAppearanceDraft) -> ChatListAppearance`

Parse hex → UIColor, apply corner mapping, carry accent + scroll gradient + bubble
gradients + wallpaper fields. Reuse existing parse helpers in the file when present.

### 5. Pure helpers (no UI hosting)

Implement pure functions (names may be nested under an enum if cleaner):

- `interpolatedWallpaperGradient(rest:scroll:progress:)` — blend rest stops with optional
  scroll stops as scroll progress goes 0…1 (Telegram-style “4 color” idea: 2 at rest,
  second pair blends in while scrolling). Progress clamped 0…1.
- `semanticAccentTokens(from accent: UIColor, isDark: Bool)` — returns contrast-safe
  tints for media chrome (waveform, play fill, media plate). Prefer WCAG-ish contrast
  against dark/light bubble plates; fall back to `brandAccentFallback` if needed.

You may leave the existing `ChatAppearancePreviewSpec` / mock live-preview types in
place if removing them risks breakage — **do not** expand them as the real solution.
Prefer the new draft contract. Additive only for public names.

## Do NOT

- Touch `ChatListView.swift`, `ChatListViewCells.swift`, `SettingsView.swift`,
  `ChatEngine.swift`, the server, migrations, or create other new files.
- Run `xcodebuild`, build/launch the app, or start simulators.
- Commit, push, `git checkout/reset/stash`.
- Build a fake chat preview host. Integrator owns live preview later.

## Acceptance

- `ChatAppearanceDraft` exists with the frozen field names.
- `ChatListAppearance` has `accent`, `messageCornerRadius`, `wallpaperScrollGradient`
  with backward-compatible defaults.
- `from(draft:)` maps correctly; corner mapping is 4 + n*22 pt.
- Pure helpers for scroll-gradient blend + accent semantic tokens exist.
- Append a short summary + exact public API names to the board Handoff section:
  `.vibe/team/appearance-0716-board.md` under `### grok — …`
