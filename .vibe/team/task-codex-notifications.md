# Brief — codex — Notifications server (production)

You are a team worker. Read the shared board `.vibe/team/settings-0716-1424-board.md`
and the contract `docs/settings-account-architecture.md` (sections "HTTP API" and the
notification-preference shape) FIRST.

## Objective

Bring the notification-preferences backend to production grade so the iOS Settings
screen can read and persist a full, validated preference object.

## You OWN (edit ONLY these)

- `server/lib/vibe_web/controllers/settings_controller.ex`
- `server/lib/vibe/notifications.ex`
- `server/lib/vibe/schemas/notification_preference.ex`

## Contract (must match exactly — the integrator wires iOS + router to this)

- Canonical preference object, top-level keys: `privateChats`, `groupChats`,
  `channels`, `stories`, `reactions`, `allAccounts`, `inAppSounds`, `inAppVibrate`,
  `inAppPreview`, `namesOnLockScreen`.
- Each **category** value (privateChats/groupChats/channels/stories/reactions) is
  `{enabled: boolean, sound: string | null, preview: boolean}`. The remaining keys are
  plain booleans.
- Controller actions:
  - `index` → returns the canonical object (defaults for any unset field).
  - `update` → validates and replaces ONLY provided fields (partial update; reject
    unknown keys / wrong types with 422).
- Persist per-user via the `notification_preference` schema + `notifications.ex`
  context (get-or-default + upsert). Do NOT invent per-account columns beyond what the
  schema needs for this object.

## Do NOT

- Touch `router.ex` (the integrator adds/reconciles the routes — just implement the
  two controller actions named `index` and `update` with the shapes above).
- Touch any iOS file, `SettingsView.swift`, a migration, or another worker's files.
- Commit, push, build the app, or launch anything.

## Acceptance

- `mix compile` clean.
- `index` returns the full canonical object with sane defaults for a user with no row.
- `update` with a partial body persists only those fields and 422s on bad input.
- Append a short summary + the exact JSON shape you return to the board's Handoff
  section (the integrator needs it to wire iOS).
