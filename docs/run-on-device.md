# Run Vibe on my physical iPhone

When the user says **"run it on my mobile" / "launch it on my device"**, they mean:
build the iOS app for the attached iPhone, install it, and launch it there.

## The device

The user's connected device (as of 2026-07-01):

| Name       | Model              | UDID (xcodebuild / xctrace)              | CoreDevice id (devicectl)                |
|------------|--------------------|------------------------------------------|------------------------------------------|
| **iPhone** | iPhone 16 Pro Max  | `00008140-000935000288801C`              | `D7D31960-610F-525B-886C-0AAE1C624F0E`   |
| iPhone 2   | iPhone 13 Pro Max  | `00008110-000A7036018B801E`              | `39B5F74C-6D8A-59D3-ADA7-076AAF454718`   |

Default target = **"iPhone" (iPhone 16 Pro Max)** — the actively connected one.
Re-check anytime with:

```bash
xcrun devicectl list devices        # shows State = connected
xcrun xctrace list devices          # shows the UDID form
```

## Project facts

- Project: `ios/Vibe.xcodeproj`   • Scheme: `Vibe`
- Bundle id: `com.vibegram.app`   • Team: `BXY4DH6H7D` (automatic signing)

## Steps

### 1. Build for the device — FREE (auto-approved)

Building never needs approval. Uses the device UDID as the destination:

```bash
xcodebuild -project ios/Vibe.xcodeproj -scheme Vibe \
  -configuration Debug \
  -destination 'platform=iOS,id=00008140-000935000288801C' \
  -derivedDataPath /tmp/vibe-device-build \
  -allowProvisioningUpdates \
  build
```

Output app bundle:
`/tmp/vibe-device-build/Build/Products/Debug-iphoneos/Vibe.app`

### 2. Install onto the phone — FREE (auto-approved)

Copying the built app onto the device has no observable effect until it's run, so
it's auto-allowed same as build:

```bash
xcrun devicectl device install app \
  --device 00008140-000935000288801C \
  /tmp/vibe-device-build/Build/Products/Debug-iphoneos/Vibe.app
```

### 3. Launch on the phone — ASKS FIRST (needs approval)

Actually running the app on the physical phone is **not** auto-approved on purpose —
the agent must get a yes before it opens on the device.

```bash
xcrun devicectl device process launch \
  --device 00008140-000935000288801C \
  com.vibegram.app
```

`--device` also accepts the name (`--device iPhone`) or the CoreDevice id.

## Approval policy (ties into ~/.vibe/agent-config.toml)

- **Build** (`xcodebuild ... build`, `swift build`) → auto-allowed (built-in safe list).
- **Install onto device** (`devicectl device install app`) → auto-allowed (just
  copies files, no running app is affected).
- **Launch on device** (`devicectl device process launch`, `ios-deploy -L`) →
  intentionally NOT in the allow-list → prompts for approval.
- The user's rule: *"the build and install are free — just ask before launching on my phone."*

## Notes

- If signing fails, open the project once in Xcode to let it register the
  provisioning profile, then retry (the `-allowProvisioningUpdates` flag usually
  handles it headlessly).
- Do **not** run these from this repo's automation agent unless the user asked to
  "run it on my mobile" — they trigger a real install on a real phone.
