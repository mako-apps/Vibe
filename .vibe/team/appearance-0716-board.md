# Team run: appearance-0716 — Telegram-class live appearance system

Architect/integrator: Claude (Opus). Workers: grok, codex, agy — each owning a
**disjoint** file so they cannot collide. Goal: a production-grade, **modern, clean,
NOT-copied** appearance editor like Telegram's — three tabs (Background / Accent /
Messages), a Message-Corners radius control, and a custom color picker (hue wheel +
hex). The live preview itself is **integrator-owned** (it injects a draft appearance
into the real chat) — workers build the model, the cell consumption, and the editor UI
that feed it. Do **not** build a fake/mock preview.

## Reference screenshots (READ THEM — pass the path to your image tool)

- `/Users/mohammadshayani/Downloads/Screenshot 2026-07-16 at 14.51.59.png`
  — Telegram editor: top tabs **Background · Accent · Messages**; gradient message
  bubbles; an **Animate / ▶ / Colors** row; **4 color swatches** + hex field
  `#5C5CC5`; a full **hue picker** (rainbow) + a brightness slider; Cancel / **Set**.
- `/Users/mohammadshayani/Downloads/Screenshot 2026-07-16 at 14.54.33.png`
  — **Message Corners** screen: doodle wallpaper behind the *real* chat; a
  **corner-radius slider** with notches (min→max) live-updating real bubbles;
  Cancel / **Set**.

Design goal from these: (1) Background = a multi-stop gradient where a SECOND pair of
colors blends in as you scroll (Telegram's 2-at-rest + 2-on-scroll = "4 color"), over
the doodle pattern. (2) Accent = one chosen color that drives media/cell chrome — voice
**waveform**, **play button**, plates, selected/inner accents. (3) Messages = the
outgoing/incoming **bubble gradient**. (4) Corners = one normalized radius. (5) Custom
colors via hue wheel + hex. Clean, modern, our own visual language (Vibe Aurora), not a
Telegram clone.

## FROZEN CONTRACT (payload barrier — everyone codes against THESE names)

### 1. `ChatAppearanceDraft` — the versioned, platform-neutral edit/persistence type

grok creates this Swift type in `ChatListViewAppearance.swift`. agy binds to it. All
colors are **hex strings** (`#RRGGBB` / `#RRGGBBAA`) — NOT UIColor — so it persists and
crosses the wire. Exact shape:

```
struct ChatAppearanceDraft: Equatable, Codable {
  var version: Int = 1
  var mode: String = "dark"                 // "dark" | "light" | "system"
  var themeId: String? = nil                // preset id, or nil for custom

  // Background
  var wallpaperKind: String = "gradient"    // "builtin" | "solid" | "gradient" | "custom"
  var wallpaperGradient: [String] = ["#05050B", "#05050B"]          // rest stops
  var wallpaperGradientLocations: [Double] = [0.0, 1.0]
  var wallpaperScrollGradient: [String] = []  // OPTIONAL 2nd pair blended on scroll ("4-color")
  var wallpaperPatternMaskKey: String? = "doodles"
  var wallpaperPatternOpacity: Double = 0.17

  // Messages (bubbles)
  var bubbleMeGradient: [String] = ["#8B7CFF", "#08C6B4"]
  var bubbleThemGradient: [String] = ["#252936", "#1A202C"]

  // Accent (drives media/cell chrome)
  var accent: String = "#2F9E93"            // hex

  // Corners
  var messageCornerRadius: Double = 0.62    // NORMALIZED 0.0…1.0 (see mapping below)

  // Misc
  var textScale: Double = 1.0
  var animationsEnabled: Bool = true
}
```

**Canonical corner mapping (ONE source of truth — put it in the contract):**
`radiusPt = 4 + normalized * 22`  → normalized 0…1 maps to **4pt…26pt**. The editor
slider, the appearance model, and the cells ALL use this exact mapping. Do not invent a
second one.

### 2. `ChatListAppearance` new stored fields (grok adds; codex consumes by name)

Add these three fields to the existing `ChatListAppearance` struct, and add an
**explicit initializer that defaults every NEW field** so the ~14 existing call sites
that build a `ChatListAppearance` keep compiling unchanged:

```
let accent: UIColor                    // default: ChatListAppearance.brandAccentFallback
let messageCornerRadius: CGFloat       // default: 18  (== mapping at normalized 0.636)
let wallpaperScrollGradient: [UIColor] // default: []  (empty = no scroll blend)
```

Requirement: existing `ChatListAppearance(...)` constructions elsewhere MUST NOT need
editing. Provide the init with these three defaulted (and keep `static let fallback` /
`static let default` valid). This is the #1 build risk — get it exactly right.

### 3. `ChatListAppearance.from(draft:)` (grok owns) — maps hex-string draft → UIColor model

Parses hex → UIColor, applies the corner mapping, carries accent + scroll gradient.

## Ownership (edit ONLY your file)

| Worker | Owns (edit ONLY this) | Consumes (read-only) |
|---|---|---|
| grok  | `ios/ChatModule/ChatListViewAppearance.swift` | the frozen contract above |
| codex | `ios/ChatModule/ChatListViewCells.swift` | `ChatListAppearance.accent`, `.messageCornerRadius` (frozen names) |
| agy   | `ios/ChatModule/AppearanceEditorView.swift` (**NEW file**) | `ChatAppearanceDraft` (frozen shape) only |

## Hard rules (all workers)

- **Edit ONLY your file.** Do NOT touch `ChatListView.swift`, `ChatEngine.swift`,
  `SettingsView.swift`, the server, migrations, or another worker's file — the
  integrator wires those. (`ChatListView.swift`/`ChatEngine.swift` are being edited by a
  SEPARATE run right now — touching them WILL corrupt it.)
- **Do NOT** `git commit/push/checkout/reset/stash`, **do NOT** run `xcodebuild` or
  launch any app. Edit files with your tools; do not use the shell to cat/fetch file
  contents or create scratch files.
- **Additive only.** Add fields/functions; never rename or remove existing public
  names/signatures. Everything must stay backward-compatible.
- **Code against the FROZEN CONTRACT names above** even though you can't build yet — the
  integrator does the single build after both runs settle. Getting names exactly right
  is how the integration compiles first try.
- Read the two reference screenshots (paths above) with your image tool if you can; the
  textual design spec in your brief is authoritative if you cannot.

## Dispatch status

| Worker | Brief | Status | Started |
|---|---|---|---|
| grok | `.vibe/team/task-grok-appearance-0716.md` | **completed** | 2026-07-16 |
| codex | `.vibe/team/task-codex-appearance-cells-0716.md` | **completed** | 2026-07-16 |
| agy | `.vibe/team/task-agy-appearance-editor-0716.md` | **completed** | 2026-07-16 |

## Handoff — append your handoff here when done

### agy — Appearance Editor UI
- **What changed**:
  - Created a new SwiftUI file [AppearanceEditorView.swift](file:///Users/mohammadshayani/Vibe/ios/ChatModule/AppearanceEditorView.swift) to provide a modern, glass-friendly, dark-themed appearance editor following the Vibe Aurora (violet/teal) style.
  - Implemented three visual tabs: **Background**, **Accent**, and **Messages**, allowing modification of the background gradient, scroll gradient, pattern mask/opacity, accent color, and bubble gradients.
  - Added a custom HSB Color Picker combining a 2D Saturation-Brightness grid, Hue rainbow slider, Brightness/Value slider, and manual Hex text input (#RRGGBB).
  - Wired the Message Corners slider utilizing the normalized 0...1 `messageCornerRadius` value with notches and text representation.
  - Configured Cancel / Set actions using standard closures.
- **Exact new public API**:
  ```swift
  struct AppearanceEditorView: View {
      @Binding var draft: ChatAppearanceDraft
      var onCancel: () -> Void
      var onSet: (ChatAppearanceDraft) -> Void
      var showsLiveChatPreview: Bool = false
  }
  ```
- **Open risks**: Depends on the swift model `ChatAppearanceDraft` being created by grok in `ChatListViewAppearance.swift`. Once grok's changes land, the integration will compile cleanly.

### grok — contract + pure helpers (2026-07-16)

**File:** `ios/ChatModule/ChatListViewAppearance.swift` only.

**What changed**
- Production draft → model pipeline (hex draft, UIColor model, pure helpers).
- Left existing `ChatAppearancePreviewSpec` / live-preview types in place (additive only).

**Public API (exact names)**

| Name | Kind | Notes |
|---|---|---|
| `ChatAppearanceDraft` | `struct`, `Equatable`, `Codable` | Frozen hex fields per contract |
| `ChatAppearanceDraft.default` | static | Vibe Aurora defaults |
| `ChatAppearanceDraft.from(raw:)` | static | `[String: Any]?` → draft |
| `ChatAppearanceDraft.asDictionary` | var | draft → portable dict |
| `ChatAppearanceDraft.messageCornerRadiusPoints(normalized:)` | static | **canonical** `4 + n*22` pt (0…1 → 4…26) |
| `ChatAppearanceDraft.defaultMessageCornerRadiusPoints` | static `CGFloat` | `18` |
| `ChatListAppearance.accent` | `UIColor` | default `brandAccentFallback` |
| `ChatListAppearance.messageCornerRadius` | `CGFloat` | default `18` |
| `ChatListAppearance.wallpaperScrollGradient` | `[UIColor]` | default `[]` |
| `ChatListAppearance.init(...)` | explicit | new fields **defaulted** — old call sites keep compiling |
| `ChatListAppearance.from(draft:)` | static | hex draft → UIColor model + corner mapping |
| `ChatListAppearance.from(raw:)` | updated | also reads `accent` / `messageCornerRadius` / `wallpaperScrollGradient` |
| `interpolatedWallpaperGradient(rest:scroll:progress:)` | free func | rest↔scroll blend, progress clamped 0…1 |
| `semanticAccentTokens(from:isDark:)` | free func | → `ChatAppearanceAccentTokens` |
| `ChatAppearanceAccentTokens` | struct | `accent`, `waveform`, `playFill`, `mediaPlate` |

**Consumer notes**
- **codex:** `appearance.accent`, `appearance.messageCornerRadius` (points, already mapped).
- **agy:** bind to `ChatAppearanceDraft`; corners via `messageCornerRadiusPoints(normalized:)`.
- **integrator:** inject `ChatListAppearance.from(draft:)` into real `ChatListView`.

**Open risks**
- Did not run `xcodebuild` (per brief). Integrator owns single build after settle.
- `from(draft:)` treats `mode == "system"` as dark until traits applied upstream.
- Legacy preview path still uses older scale-based corner math; production path is draft mapping only.

### codex — production cell appearance consumption (2026-07-16)

**File:** `ios/ChatModule/ChatListViewCells.swift` only.

**What changed**
- Added private `chatAppearanceBubbleShape(_:appearance:)`: rebases the legacy 18pt
  `BubbleShape` radii onto `appearance.messageCornerRadius`; reduced grouped corners keep
  their existing proportion (with a 2pt floor for positive tight corners).
- Applied the resolved shape at every production `bubbleView.configure` path (regular,
  agent, agent mention, and transparent streaming) and to full-bleed/caption media masks
  plus their border paths.
- Voice waveform active/inactive bars, voice play fill/ring/icon contrast, selection
  circles, video/video-note play plates, and media borders now consume
  `appearance.accent` (alpha variants where appropriate).
- Added private luminance-based foreground selection so light custom accents receive a
  dark play glyph and darker accents receive a white glyph.

**Public API:** none; all existing cell/configure signatures remain unchanged.

**Intentionally still hard-coded**
- Tail visibility/geometry and circular controls (voice/video-note buttons, progress
  rings, reaction/day pills) remain shape/layout constants because they are not message
  bubble corner radii.
- Caption media bottom corners remain a tight fixed 5pt seam; only their exposed outer
  top corners track the message radius.
- Agent working-state accents remain task-specific overrides; the normal production
  media/selection chrome follows `appearance.accent`.

**Verification / risk**
- Audited exact frozen property references after grok's contract landed.
- Did not run `xcodebuild` or launch (explicit worker brief); integrator owns the shared build.
