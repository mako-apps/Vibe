# Brief — agy — Appearance editor UI only (new file)

You are a team worker doing **UI only**. Read the shared board **first**:
`.vibe/team/appearance-0716-board.md`

You bind **only** to `ChatAppearanceDraft` (frozen shape on the board). You do
**not** render the real chat and do **not** know about cell internals.

## Objective

Create a modern, clean, **Vibe-native** (not a Telegram clone) appearance editor
with three tabs + a corners control + custom color picker, matching the *ideas*
in the screenshots:

- `/Users/mohammadshayani/Downloads/Screenshot 2026-07-16 at 14.51.59.png`
  — top tabs **Background · Accent · Messages**; swatches + hex; hue wheel +
  brightness; Cancel / Set.
- `/Users/mohammadshayani/Downloads/Screenshot 2026-07-16 at 14.54.33.png`
  — **Message Corners** slider (normalized radius).

Open those images if your tools allow. Learn structure; do **not** copy pixels.

## You OWN (create/edit ONLY this file)

- `ios/ChatModule/AppearanceEditorView.swift`  (**NEW**)

`ChatModule/` is already an Xcode sources path — a new file there is enough.
Do **not** edit `project.yml`.

## Contract you bind to (exact field names)

```
struct ChatAppearanceDraft {
  var version: Int
  var mode: String
  var themeId: String?
  var wallpaperKind: String
  var wallpaperGradient: [String]
  var wallpaperGradientLocations: [Double]
  var wallpaperScrollGradient: [String]
  var wallpaperPatternMaskKey: String?
  var wallpaperPatternOpacity: Double
  var bubbleMeGradient: [String]
  var bubbleThemGradient: [String]
  var accent: String                    // hex
  var messageCornerRadius: Double       // NORMALIZED 0…1
  var textScale: Double
  var animationsEnabled: Bool
}
```

Corner display hint (do not reimplement cells):
`radiusPt = 4 + normalized * 22` (4…26 pt). Slider edits the **normalized** value.

Assume `ChatAppearanceDraft` will exist in `ChatListViewAppearance.swift` (another
worker). Use that type by name. If the type is not yet on disk when you start,
still write against these field names so integration compiles once grok lands.

## Required UI surface

Public entry the integrator can present later, e.g.:

```swift
struct AppearanceEditorView: View {
  @Binding var draft: ChatAppearanceDraft
  var onCancel: () -> Void
  var onSet: (ChatAppearanceDraft) -> Void
  // optional: var showsLiveChatPreview: Bool = false  // leave unused/false
}
```

### Tabs

1. **Background**
   - Edit rest gradient stops (at least 2 hex colors) + optional scroll pair
     (`wallpaperScrollGradient`, 0–2 colors).
   - Pattern mask key picker for known keys (`doodles`, `music`, …) or free string.
   - Pattern opacity slider.
2. **Accent**
   - Single accent hex via swatches + custom picker.
3. **Messages**
   - Me / them bubble gradient stops (2 colors each).

### Shared chrome

- Segmented/tab control: Background | Accent | Messages
- **Message Corners** row/slider: 0…1 normalized → write `draft.messageCornerRadius`
- **Color picker**: hue wheel (or gradient spectrum) + brightness/value slider + hex
  text field (`#RRGGBB`). When the active target changes (accent / bubble stop /
  wallpaper stop), edits apply to that target.
- **Cancel** / **Set** buttons calling the closures (Set passes current draft).

Visual language: dark, modern, glass-friendly, **Vibe Aurora** (violet/teal), not
Telegram blue clone. Prefer SwiftUI. Keep structure simple and robust — avoid
fragile multi-layer hacks that break layout.

## Do NOT

- Touch any other file (`SettingsView`, `ChatListView*`, server, project.yml, …).
- Embed a fake chat preview with mock bubbles. Preview is integrator-owned.
- Run `xcodebuild`, build, or launch the app.
- Commit, push, `git checkout/reset/stash`.
- Invent alternate draft field names.

## Acceptance

- New file `ios/ChatModule/AppearanceEditorView.swift` exists.
- Three tabs + corners slider + hue/hex color editing bind to `ChatAppearanceDraft`.
- Cancel / Set wired via closures.
- Append summary + exact public type names to
  `.vibe/team/appearance-0716-board.md` under `### agy — …`
