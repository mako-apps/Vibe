# Vibe — agent guide (Grok)

Grok loads this file automatically as project rules (see xAI docs: Project Rules /
`AGENTS.md`). Supported top-level names: `Agents.md`, `AGENTS.md`, `AGENT.md`,
`Claude.md`, `CLAUDE.md`, `CLAUDE.local.md`. **`GROK.md` is not a recognized
filename** — use this file (or `.grok/rules/*.md`) for Grok-native rules.

Also loaded when present: `CLAUDE.md` (Claude Code compat). Deeper paths win on
conflicts. Inspect with: `grok inspect`.

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

## After any iOS code change — build and fix

**Required:** whenever you patch, add, or refactor files under `ios/`, run an
`xcodebuild` for scheme `Vibe` and **fix compile errors before considering the
task done**. Do not leave a broken build for the user.

```bash
xcodebuild -project ios/Vibe.xcodeproj -scheme Vibe \
  -configuration Debug \
  -destination 'platform=iOS,id=00008140-000935000288801C' \
  -derivedDataPath /tmp/vibe-device-build \
  -allowProvisioningUpdates \
  build
```

If the physical phone is offline, use a simulator destination instead
(`platform=iOS Simulator,name=iPhone 16`). On failure: read the error, fix the
Swift, rebuild, and repeat until green. Building is free (no approval needed).

## Tool approval config

Interactive approvals for agents in this repo are governed by
`~/.vibe/agent-config.toml` → `approval_mode`:

- `local` (default) — approve/answer everything on this device; nothing goes to the phone.
- `mobile` — route non-auto-allowed tools to the phone (falls back local if unanswered).
- `auto` — safe/allow-listed commands run without asking; only blockers go to the phone.
- `full` — allow everything except the always-blocked destructive commands.

Destructive commands (rm -rf, sudo, git push, git reset --hard, dd, mkfs, curl|sh,
npm publish, ...) are blocked in every remote mode, even `full`.

## Ask advisor on complex tasks

**Required:** on complex tasks, ask the advisor **before** you commit to an approach
or start a large implementation.

Use the Fable MCP tool **`vibeask__ask_fable`** (search tools / `use_tool` if needed).

Treat a task as complex when any of these apply:
- multi-step or multi-file design/implementation
- ambiguous requirements or several reasonable approaches
- unfamiliar, risky, or security-sensitive code
- debugging a hard failure after your first fix attempt
- architecture, API, or data-model decisions

What to send:
- `question` — the concrete decision or review you need
- `context` — goal, constraints, findings, errors, current assumptions
- optional `files` / `diff` — relevant snippets or proposed patch

Skip the advisor for simple, obvious one-liners (typos, renames, trivial edits).
Fable returns advice only — you still implement and verify. If the advisor is
unavailable (rate limit / error), note that and continue with your best judgment.

## Prefer commands that run without approval

Read-only / search / inspect commands (and pipelines of them) auto-run; commands
that mutate the filesystem or run arbitrary code stop for approval. Prefer the
auto-allowed forms and don't reach for a mutating command unless the task needs the
side effect — e.g. **don't `cp` a file just to read or diff it** (use Read / `cat` /
`diff`), and edit files with the **Edit/Write** tools (auto-allowed) instead of
`sed -i` / redirects. Full list of what runs free vs. asks:
[docs/agent-command-guide.md](docs/agent-command-guide.md).
