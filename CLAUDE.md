# Vibe — agent guide

## "Run it on my mobile" / "launch it on my device"

The user means: **build + install + launch the iOS app on their attached iPhone.**

- Target device: **"iPhone" — iPhone 16 Pro Max**, UDID `00008140-000935000288801C`
- Bundle id: `com.vibegram.app` · Project `ios/Vibe.xcodeproj` · Scheme `Vibe`
- **Building is free** — just build it (no need to ask).
- **Installing the build onto the phone is free** (`xcrun devicectl device install app`
  — just copies the binary over, no observable effect until it's run).
- **Launching it asks first** (`xcrun devicectl device process launch`) — confirm
  before the app actually runs on the real device.

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

## Ask advisor on complex tasks

When a task is complex (multi-step, ambiguous, or touches unfamiliar/risky code),
call the `advisor` tool before committing to an approach. Skip it for simple,
obvious fixes.

## Prefer commands that run without approval

Read-only / search / inspect commands (and pipelines of them) auto-run; commands
that mutate the filesystem or run arbitrary code stop for approval. Prefer the
auto-allowed forms and don't reach for a mutating command unless the task needs the
side effect — e.g. **don't `cp` a file just to read or diff it** (use Read / `cat` /
`diff`), and edit files with the **Edit/Write** tools (auto-allowed) instead of
`sed -i` / redirects. Full list of what runs free vs. asks:
[docs/agent-command-guide.md](docs/agent-command-guide.md).
