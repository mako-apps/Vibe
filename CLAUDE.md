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

## Ask Fable (advisor) — only when you're actually stuck

Fable runs on **paid credits** (and falls back to GPT when Fable itself is down),
so it's a **last resort, not a first step**. Solve it yourself first — diagnose,
read the code, attempt the fix. Reach for Fable only when you have genuinely tried
and **cannot** crack it: a hard bug that survives your first fix, a risky/unfamiliar
call you can't resolve from the code, or an architecture decision you're truly
unsure of. Do NOT call it just because a task looks complex or multi-step — if you
can fix it, fix it, then move on.

**If you ARE Fable** (model id `claude-fable-5` / Claude Fable 5): do NOT call the
advisor or `ask_fable` — you'd be asking yourself. Just proceed with the task.

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
→ **Ask Fable (advisor)**.

## Complex task? Diagnose yourself, then dispatch worker CLIs

When a task is multi-slice and you have FINISHED diagnosing (you know exactly what
must change where), don't patch everything yourself — dispatch worker CLIs as
background subprocesses for speed and cost. The full operating guide (loop, board
protocol, routing, review rules) is `agent-bridge/instructions/team-lead.md` — follow
it. The essentials:

- Write a board (`.vibe/team/<run>-board.md`) with FROZEN contract names + ownership
  (one owner per file, disjoint), then one self-contained brief per worker.
- Exact worker invocations (verified 2026-07-18):
  - codex: `codex exec --json -c sandbox_mode="workspace-write" -c approval_policy="never" -c model_reasoning_effort="<low|medium|high>" --cd <repo> --skip-git-repo-check "<prompt>"`
  - grok: `~/.grok/bin/grok --prompt-file <brief> --always-approve --max-turns 80 --output-format plain --cwd <repo>` (acceptEdits is silently DROPPED headless; default max-turns cuts workers off)
  - agy: `~/.local/bin/agy -p "Read and execute the brief at <path>" --mode accept-edits --dangerously-skip-permissions --print-timeout 30m` (UI/low-risk only — never auth/security/payments/migrations)
- Review DIFFS vs baseline, never handoff prose. One verify pass (compile/tests/build)
  at the end — workers never commit, build, or launch.
- **Shared agent memory**: `.vibe/memory.md` is the append-only journal all agents
  share — read it before diagnosing (what previous runs shipped/learned), append one
  short entry (Shipped / Learned / Open) after finishing real work.
- **Clean up when the run settles**: fold durable learnings into docs/memory, then
  delete that run's `.vibe/team/<run>*` board and brief files.
- Live status: the lead prints `VIBE_TEAM_STATUS {"worker":"codex","state":"spawn|running|done|failed","label":"..."}`
  on its own stdout at every worker spawn/start/finish so the phone shows a live
  per-worker board — avatar + elapsed clock ticking from the `spawn` beat.

## Prefer commands that run without approval

Read-only / search / inspect commands (and pipelines of them) auto-run; commands
that mutate the filesystem or run arbitrary code stop for approval. Prefer the
auto-allowed forms and don't reach for a mutating command unless the task needs the
side effect — e.g. **don't `cp` a file just to read or diff it** (use Read / `cat` /
`diff`), and edit files with the **Edit/Write** tools (auto-allowed) instead of
`sed -i` / redirects. Full list of what runs free vs. asks:
[docs/agent-command-guide.md](docs/agent-command-guide.md).
