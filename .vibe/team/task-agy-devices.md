# Brief — agy — Devices / sessions server (production)

You are a team worker. Read the shared board `.vibe/team/settings-0716-1424-board.md`
and the contract `docs/settings-account-architecture.md` (sections "Trust model" and
"HTTP API") FIRST. Read your files with your tools — do NOT use the shell to cat files
and do NOT create scratch/temp files.

## Objective

Bring linked-device + session management to production grade: listing devices,
revoking a device (which revokes its sessions), and listing/revoking sessions.

## You OWN (edit ONLY these)

- `server/lib/vibe_web/controllers/account_device_controller.ex`
- `server/lib/vibe/accounts.ex` (device/session functions only)
- `server/lib/vibe/schemas/device_session.ex`

## Contract (must match exactly)

- `index` (`GET /account/devices`) → `{devices: [{id, deviceIdentifier, name, platform,
  current, lastSeenAt, createdAt}]}`. `current` marks the requesting device.
- `delete` (`DELETE /account/devices/:id`) → `204`; **revoking a device revokes all its
  sessions**.
- `sessions` (`GET /account/sessions`) → the caller's sessions.
- `delete_session` (`DELETE /account/sessions/:id`) → revokes one session.
- `register_current` → upserts the calling device + refreshes `lastSeenAt`.
- Session bearer tokens are random high-entropy, returned once, stored as SHA-256
  hashes. Never return a stored token. Expired/revoked/consumed rows cannot be used.

## Do NOT

- Touch `router.ex` (routes already exist — just make the controller actions
  production-correct), any iOS file, `SettingsView.swift`, a migration, or another
  worker's files (notifications.ex belongs to codex).
- Commit, push, build the app, or launch anything.

## Acceptance

- `mix compile` clean.
- Deleting a device cascades to its sessions; `current` flag is correct; tokens are
  never leaked in responses.
- Append a short summary + any response-shape detail the integrator must wire on iOS to
  the board's Handoff section.
