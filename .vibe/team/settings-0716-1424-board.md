# Team run: settings-0716-1424 — Settings production hardening

Architect/integrator: Claude (Opus). Workers: codex, agy, grok — running as local
CLIs, each owning a **disjoint** file set so they cannot collide.

Shared spec (READ FIRST): `docs/settings-account-architecture.md` — the canonical
contract for HTTP API, notification-preference shape, device sessions, appearance.

## Ownership (edit ONLY your files)

| Worker | Area | Owns (edit only these) |
|---|---|---|
| codex | Notifications server | `server/lib/vibe_web/controllers/settings_controller.ex`, `server/lib/vibe/notifications.ex`, `server/lib/vibe/schemas/notification_preference.ex` |
| agy | Devices server | `server/lib/vibe_web/controllers/account_device_controller.ex`, `server/lib/vibe/accounts.ex` (device fns only), `server/lib/vibe/schemas/device_session.ex` |
| grok | Appearance preview (iOS) | `ios/ChatModule/ChatListViewAppearance.swift` |
| Claude (integrator) | hub + wiring | `SettingsView.swift`, `router.ex`, `AgentConnectView.swift`, migrations, review, build, install |

## Hard rules (all workers)

- **Edit ONLY your files.** Do NOT touch `router.ex`, `SettingsView.swift`, any other
  worker's files, or any migration — the integrator wires those.
- **Do NOT** `git commit`, `git push`, `git checkout/reset/stash`, build the iOS app,
  or launch any app. Server workers MAY run `mix compile` / `mix format` to verify.
- Read and edit files with your tools. Do **not** create scratch/temp files or use the
  shell to fetch file contents — open them directly.
- Keep public function names/signatures stable; add fields, don't rename/remove.

## Handoff — append your result here when done

(workers append: what changed, any API shape the integrator must wire, open risks)

### codex — Notifications server

- Added canonical defaults/normalization and strict partial validation (including nested category fields), plus per-user get-or-default/upsert in `Vibe.Notifications`.
- Added `SettingsController.index/2` and `update/2`; both success responses are the canonical object directly (no `notifications` wrapper). Partial updates deep-merge only provided fields. Unknown keys and wrong types return HTTP 422.
- Message-push enablement now reads the same canonical category preferences.
- `mix format` passed. The sandbox blocked `mix compile` before project compilation because Mix PubSub could not open its local TCP socket (`:eperm`); direct compilation of all three changed modules and focused changeset/validation checks passed.

Exact JSON returned by both `GET /api/account/notification-preferences` and a successful `PUT /api/account/notification-preferences` (shown with defaults):

```json
{
  "privateChats": {"enabled": true, "sound": "default", "preview": true},
  "groupChats": {"enabled": true, "sound": "default", "preview": true},
  "channels": {"enabled": true, "sound": "default", "preview": true},
  "stories": {"enabled": true, "sound": "default", "preview": true},
  "reactions": {"enabled": true, "sound": "default", "preview": true},
  "allAccounts": true,
  "inAppSounds": true,
  "inAppVibrate": true,
  "inAppPreview": true,
  "namesOnLockScreen": true
}
```

Validation failure shape (HTTP 422; messages vary by invalid field):

```json
{
  "error": "Invalid settings",
  "details": {"preferences": ["privateChats.sound must be a string or null"]}
}
```

### agy — Devices / sessions server

- Added device and session management logic in `Vibe.Accounts` (`accounts.ex`), bypassing the old partial stubbing.
- Added `belongs_to :user` association and `active?/2` validation helper inside `DeviceSession` schema (`device_session.ex`).
- Rewrote `AccountDeviceController` (`account_device_controller.ex`) actions to call `Vibe.Accounts` and match the API contract exactly:
  - `index` (`GET /account/devices`) maps the list to return `{devices: [{id, deviceIdentifier, name, platform, current, lastSeenAt, createdAt}]}`, setting `current` correctly by checking the `x-vibe-device-id` request header.
  - `delete` (`DELETE /account/devices/:id`) revokes the device and all its associated active sessions, returning `204 No Content`.
  - `sessions` (`GET /account/sessions`) returns the calling user's active device sessions, with correct device details and `current` flag.
  - `delete_session` (`DELETE /account/sessions/:id`) revokes a single session, checking for current session, and returning `204 No Content`.
- Updated `Accounts.get_user_by_token/1` to automatically fallback to looking up bearer tokens in `device_sessions` table if not found in `users.login_token`, thus allowing secure device-scoped API session auth.
- `mix compile` and `mix format` are clean.

Exact JSON returned by `GET /api/account/devices` (shown with fields):

```json
{
  "devices": [
    {
      "id": "uuid",
      "deviceIdentifier": "string",
      "name": "string",
      "platform": "string",
      "current": true,
      "lastSeenAt": "utc_datetime",
      "createdAt": "utc_datetime"
    }
  ]
}
```

Exact JSON returned by `GET /api/account/sessions` (shown with fields):

```json
{
  "sessions": [
    {
      "id": "session_uuid",
      "deviceId": "device_uuid",
      "name": "device_name",
      "platform": "device_platform",
      "lastSeenAt": "utc_datetime",
      "createdAt": "utc_datetime",
      "expiresAt": "utc_datetime",
      "current": true
    }
  ]
}
```

Delete endpoints (both `DELETE /api/account/devices/:id` and `DELETE /api/account/sessions/:id`) return `204 No Content` on success. Revoking the current session yields a `409 Conflict` with:

```json
{
  "error": "The current session cannot be revoked"
}
```

### grok — Appearance live preview (iOS)

**File edited:** `ios/ChatModule/ChatListViewAppearance.swift` only.

**What changed (additive, no renames):**
- `ChatAppearancePreviewSpec` — persisted contract: `mode`, `themeId`, `wallpaperKind`/`wallpaperValue`, accent, two-stop bubble gradient, `textScale`, `messageCornerScale`, `animationsEnabled`. Includes `from(raw:)` + `asDictionary`.
- `ChatAppearanceSemanticTokens` — semantic tokens resolved from a spec (theme presets + overrides). Project to chat via `asChatListAppearance`.
- `ChatListAppearance.from(previewSpec:traitCollection:)` — bridge helper.
- **Live preview surface** (mock them/me bubbles + wallpaper/pattern mask, live `apply`):
  - UIKit: `ChatAppearanceLivePreview`
  - SwiftUI: `ChatAppearanceLivePreviewView`

**Integrator embed (exact name):** **`ChatAppearanceLivePreviewView`**

```swift
// Settings appearance screen — push a new spec whenever controls change:
ChatAppearanceLivePreviewView(spec: currentSpec, preferredHeight: 220)
```

Build a `ChatAppearancePreviewSpec` from mode/theme/wallpaper/accent/gradient/scales (or `ChatAppearancePreviewSpec.from(raw:)`), bind it to state, and re-render on change. Optional UIKit path: `ChatAppearanceLivePreview` + `apply(_:)`.

**API shape notes:**
- Wallpaper kinds: `builtin` | `solid` | `gradient` | `custom` (custom stays local; preview uses theme gradient stand-in).
- Theme resolution reuses existing native presets via `nativeThemeId` (glacier/zen/ocean/…).
- Does not call the chat engine.

**Open risks:** None for this slice. Wiring into `SettingsView` / replacing private `AppearanceDevicePreview` is integrator-owned. No `xcodebuild` run (per brief).

---

### codex — Devices/session security hardening

- **Already correct when independently inspected:** device-session tokens were generated from 32 cryptographically random bytes, only their SHA-256 digests were persisted, and the plaintext token was exposed only by the one-time pairing claim result. Device deletion already revoked the owned device and all of its non-revoked sessions in one transaction. Session authentication already checked session expiry/revocation plus device revocation, link-request reads already rejected consumed/rejected/expired rows, and device/session `current` flags already came from `x-vibe-device-id`. Contrary to the stale warning in the hardening brief, `Accounts.get_user_by_token/1` already contained a device-session fallback while preserving the existing `users.login_token` lookup first.
- **Fixed in this pass:** made device-session use race-safe with device-then-session row locks, ownership consistency checks, strict expiry handling, and fail-closed updates of both `device_sessions.last_used_at` and `account_devices.last_seen_at`. Pairing approval and claim now lock the request row and re-check state inside the transaction, so concurrent claims cannot both consume a code; the exact expiry boundary is rejected. Added malformed-token/code guards, defensive expiry checks, SHA-256 digest-length validation, trimmed request device identifiers, and a handled claim-validation error response.
- **Final auth lookup behavior:** a non-empty bearer token is first matched against `users.login_token` with its existing expiry/sliding behavior. Only if no login-token user exists is SHA-256(token) matched against `device_sessions`; the session resolves its non-agent user only after the session and owning device are confirmed present, mutually owned, non-revoked, and strictly unexpired, and both last-seen timestamps are updated. Expired device sessions return `:token_expired`; revoked, malformed, inconsistent, or unknown device sessions fail as invalid tokens.
- **Verification:** formatter/checks and direct compilation of all three owned Elixir modules passed, including a focused token-digest changeset check and `git diff --check`. The required `mix compile` command was attempted, but this sandbox stopped Mix before project compilation because Mix PubSub could not open its local TCP socket (`:eperm`).
