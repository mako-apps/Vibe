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

## Ask Fable (advisor) on complex tasks

**Required** on complex tasks (multi-step, ambiguous, unfamiliar/risky, hard debug,
architecture). Skip for simple one-liners.

### How to call

1. Prefer the built-in **`advisor`** tool when available.
2. Otherwise use the Fable MCP tool:
   - **`mcp__vibeask__ask_fable`** (Claude Code / bridge MCP name), or
   - **`vibeask__ask_fable`** (qualified `server__tool` form).

Pass at least:
- `question` — concrete decision/review (required)
- `context` — goal, findings, errors, assumptions
- optional `diff`, `constraints[]`, `files[{path,content,note}]`

Fable returns **plain-text advice only** (Assessment / Risks / Next steps /
Verification) via the MCP tool result — you still implement and verify. If
unavailable (rate limit / error), note it and continue.

**Usage:** keep calls lean — sharp `question`, short `context`, tiny snippets.
Default package budget is ~24k chars (`VIBE_FABLE_MCP_CONTEXT_CHARS`). Do not
paste whole files or re-ask with the same dump.

Full how-to (response path + optimise tips): see [Agents.md](Agents.md)
→ **Ask Fable (advisor) on complex tasks**.

## Prefer commands that run without approval

Read-only / search / inspect commands (and pipelines of them) auto-run; commands
that mutate the filesystem or run arbitrary code stop for approval. Prefer the
auto-allowed forms and don't reach for a mutating command unless the task needs the
side effect — e.g. **don't `cp` a file just to read or diff it** (use Read / `cat` /
`diff`), and edit files with the **Edit/Write** tools (auto-allowed) instead of
`sed -i` / redirects. Full list of what runs free vs. asks:
[docs/agent-command-guide.md](docs/agent-command-guide.md).
