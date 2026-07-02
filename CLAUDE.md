# Vibe — agent guide

## "Run it on my mobile" / "launch it on my device"

The user means: **build + install + launch the iOS app on their attached iPhone.**

- Target device: **"iPhone" — iPhone 16 Pro Max**, UDID `00008140-000935000288801C`
- Bundle id: `com.vibegram.app` · Project `ios/Vibe.xcodeproj` · Scheme `Vibe`
- **Building is free** — just build it (no need to ask).
- **Installing / launching on the phone asks first** — confirm before the app lands
  on the real device.

Exact commands + device table: [docs/run-on-device.md](docs/run-on-device.md).

## Tool approval config

Interactive approvals for Claude Code in this repo are governed by
`~/.vibe/agent-config.toml` → `approval_mode`:

- `local` (default) — approve/answer everything on this device; nothing goes to the phone.
- `mobile` — route non-auto-allowed tools to the phone (falls back local if unanswered).
- `auto` — safe/allow-listed commands run without asking; only blockers go to the phone.
- `full` — allow everything except the always-blocked destructive commands.

Destructive commands (rm -rf, sudo, git push, git reset --hard, dd, mkfs, curl|sh,
npm publish, ...) are blocked in every remote mode, even `full`.
