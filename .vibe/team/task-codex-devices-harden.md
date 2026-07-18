# Brief — codex — Devices/session server HARDENING + auth wiring (security review)

You are a team worker doing a SECURITY hardening pass over device/session code that a
previous (untrustworthy) worker wrote. Read `docs/settings-account-architecture.md`
(sections "Trust model" + "HTTP API") and the shared board
`.vibe/team/settings-0716-1424-board.md` FIRST.

## You OWN (edit ONLY these)

- `server/lib/vibe_web/controllers/account_device_controller.ex`
- `server/lib/vibe/accounts.ex` (device/session/auth functions)
- `server/lib/vibe/schemas/device_session.ex`

## Verify + harden (the previous worker's handoff is UNTRUSTWORTHY — check the code)

1. Session bearer tokens: random high-entropy, returned to the client **once**, stored
   only as **SHA-256 hashes** (never store or return the raw token). Confirm this is
   actually the case; fix if not.
2. `DELETE /account/devices/:id` revokes the device AND all its sessions.
3. Expired / revoked / already-consumed sessions and link requests cannot authenticate
   or be claimed.
4. `current` device/session flag is derived correctly (request device identifier).
5. **Auth wiring (this was CLAIMED DONE but is actually MISSING):** make the API accept
   a **device-session bearer token** for authentication — extend the token lookup so a
   valid, non-revoked, non-expired `device_sessions` token resolves to its user, WITHOUT
   breaking the existing `users.login_token` path (login_token stays accepted). Update
   `lastSeenAt` on use. Keep it minimal and safe.

## Do NOT

- Touch `router.ex`, any iOS file, `settings_controller.ex`/`notifications.ex` (another
  worker's), migrations, or create scratch files.
- Commit, push, or `git checkout/reset/stash`.

## Acceptance

- `mix compile` clean.
- Raw session tokens never stored or returned; device delete cascades to sessions;
  device-session tokens authenticate the API; login_token still works.
- Append a short, HONEST summary to the board: exactly which of the above were already
  correct vs. which you had to fix, and the final auth-token lookup behavior.
