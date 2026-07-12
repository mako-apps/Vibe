# Vibe Team Architecture v2 — planner / workers / code-monitor

Status: DESIGN (2026-07-12). Supersedes the v1 "supervisor lead does everything" flow.
Research base: Anthropic multi-agent engineering lessons, MAST failure taxonomy,
durable-execution and complexity-tier routing patterns. Key numbers that shaped this
design: multi-agent runs cost ~15× a single chat; ~80% of outcome quality tracks token
budget; the #1 failure causes in production multi-agent systems are ambiguous task
specs, coordination breakdowns, and missing verification — not model quality.

## Principles

1. **Deterministic code owns the loop; models own judgment.** Liveness, retries,
   reassignment, iteration, and completion are server code (OTP), never an LLM burning
   context. Models are called at exactly three judgment points: plan, work, summarize.
2. **Spend tokens where the tier justifies it.** Chat and simple asks never pay the
   team tax. A team run is only for genuinely decomposable multi-part work.
3. **Task specs kill failures.** Every worker gets an explicit objective, exact file
   list, interface contracts, output format, boundaries, and an effort budget.
4. **Coding needs disjoint ownership.** Multi-agent is weakest on tightly-coupled
   code. The plan must produce vertical, file-disjoint slices with shared contracts
   (schema, API shapes) fixed up front; shared files belong to one integrator.
5. **Everything resumable.** Run state (plan, task table, worker states) lives in the
   DB (`TeamRun`), not in any model's context. Server restart or bridge flap re-arms
   the run from persisted state.

## Pipeline

```
group message
   │
   ├─ explicit @mention ──────────────► that agent, solo (unchanged)
   │
   ▼
[1] CLASSIFY (server, ~0 tokens)
   heuristics + optional 1 Haiku call (agent_runtime has ANTHROPIC_API_KEY)
   → chat        : one agent replies, no preamble, no team          (cost: 1 chat)
   → simple      : one agent solo run, full CLI, no team            (cost: 1 run)
   → complex     : team pipeline below; suggested worker count 2..N
   `@team` forces classify ≥ simple → planner decides scale.
   │
   ▼
[2] PLAN (1 advisor call — Fable; Sol fallback; lead-self-plan last resort)
   input : task text + repo map (file tree + README head — never full code)
   output: STRUCTURED JSON plan persisted to TeamRun + handoff file:
     architecture   — pages/routes, backend endpoints, DB schema, styling system
     contracts      — API shapes, schema, naming; lets FE/BE build independently
     task_table     — rows: {worker, objective, files[] (disjoint), output_format,
                      boundaries, effort_budget, fallback_provider}
     integrator     — one worker (default codex) owning shared files + final build
     verification   — checklist: every page/endpoint/schema + "build passes;
                      tests if present"
     open_questions — anything that must be asked via the ask sheet BEFORE
                      dispatch (e.g. which database) when the user didn't specify
   Worker count comes from the plan (effort scaling), not "always everyone".
   │
   ▼
[3] DISPATCH (server → bridge, parallel)
   each worker prompt = its row + contracts + handoff protocol ONLY (scoped
   context; explicitly told to read only its assigned paths). Gemini/agy always
   gets a fully enumerated file list. Ask-sheet available to workers (existing).
   │
   ▼
[4] MONITOR — TeamRunMonitor GenServer per run (0 model tokens)
   per-row state machine:
     dispatched → running → done | failed | stalled | limited
   signals: bridge stream frames = heartbeat; done/exit events; usage-limit
   classifier (bridge already detects rate/usage-limit text).
   interventions:
     stalled  (no frames > stall_timeout)  → cancel + retry same provider (once)
     failed   (exit ≠ 0 / crash)           → retry same provider (once)
     limited  (usage/rate limit)           → reassign row to fallback_provider,
                                             marked "reassigned → <provider>"
     retry exhausted                       → row = failed; run continues; gap
                                             report includes it
   persistence: every transition written to TeamRun.worker_states; monitor
   rehydrates from DB on server restart, re-arms watches on bridge reconnect
   (rehydrate_team_workers_from_running_tasks already exists).
   emits: `agent-team-worker` events → iOS progress nodes (running/editing/
   done/failed/reassigned) — the run's single visible cell.
   │
   ▼ all rows terminal
[5] VERIFY + INTEGRATE (integrator worker, 1 scoped run)
   input: verification checklist + gap report (missing/failed rows) — not the
   full transcripts. Runs the build, integrates shared files, fixes gaps it can.
   If checklist items remain → monitor respawns targeted workers with a
   gap-scoped task list. Hard cap: 2 gap rounds (cost ceiling), then report
   honestly what is missing.
   │
   ▼
[6] SUMMARIZE (cheap)
   one small-model call over the handoff file + checklist result (never full
   transcripts): what each agent did, what landed, what remains. Posted as the
   team cell's body; only then does the cell settle/collapse.
```

## UI payload (iOS — mostly shipped, small deltas)

- One visible cell per team run (exists: lead cell + `teamWorkersStatus` strip).
- Per-worker progress nodes in that cell: `Claude — running`, `Agy — editing`,
  `Grok — done`, `Codex — reassigned → Claude`; tap → existing worker detail
  view (subagent detail infra shipped). No collapse until [6] posts the summary.
- New node statuses to render: `stalled`, `retrying`, `reassigned`, `verifying`,
  plus a final `summary` event that sets the cell body and ends the run.
- Phase labels on the cell: `Planning…` (advisor), `Building (3 workers)…`,
  `Verifying…`, settled summary.

## Usage economy (why this reduces spend vs v1)

| stage        | v1 (today)                              | v2                                   |
|--------------|------------------------------------------|--------------------------------------|
| casual "hi"  | full lead CLI run (sometimes 4-way fan-out) | 1 chat-tier reply, zero team tax  |
| simple fix   | lead run + often needless spawns         | 1 solo run                           |
| classify     | lead CLI session decides (expensive)     | heuristic + 1 Haiku call (~cents)    |
| plan         | lead "thinks about it" inside a long session | 1 scoped advisor call            |
| coordination | lead session stays alive re-reading everything | GenServer, 0 tokens            |
| workers      | vague focus → repo-wide reads, duplicate work | file-scoped rows, budgets       |
| summary      | lead re-reads the world                  | 1 small-model call over handoff      |

The group_default_parallel path (plain message → ALL agents run full CLI sessions)
is the single biggest waste in v1 and is replaced by classify-then-route.

## Failure scenarios covered

- worker crash / nonzero exit → bounded retry, then gap report
- worker silent hang → stall timeout → retry
- provider usage/rate limit → reassign row to fallback provider, loop unbroken
- bridge disconnect mid-run → persisted state + reconnect rehydration
- server deploy/restart mid-run → monitor rehydrates from TeamRun row
- advisor down → Sol fallback → lead-self-plan (run never blocks on advisor)
- user cancels → existing cancel path tears down all rows (shipped)
- plan needs a user decision (e.g. database choice) → ask sheet BEFORE dispatch,
  with timeout → planner default, recorded in the plan

## Review amendments (Fable, 2026-07-12)

- **Row states gain `queued`.** All workers execute on one Mac bridge; a per-bridge
  run queue with max concurrency prevents false stalls (stall timer starts at
  `running`, not `queued`). Retry caps are per RUN as well as per row so
  retry-once × N rows cannot storm the bridge.
- **File boundaries are advisory.** Workers will inevitably brush shared files
  (lockfiles, generated code). The integrator owns conflict resolution; boundaries
  guide, they don't hard-fail.
- **Plans are schema-validated.** Invalid JSON → one repair retry → legacy
  VIBE_TEAM_SPAWN lead flow. Never dispatch on an unvalidated plan.
- **Transitions are idempotent** on `{run_id, row, seq}` — bridge rejoin-recovery
  re-delivers events.
- **Plain group messages keep 4-way fan-out.** Classify-then-route applies to
  `@team` runs first (per-group flag for the rest). The chit-chat waste is later
  solved by cheap chat-mode replies, not by silently dropping the 4-reply UX.
- **Monitor OTP shape**: DynamicSupervisor + Registry keyed `{chat_id, run_id}`,
  `:transient` restart, TeamRun DB row is the source of truth, GenServer holds only
  ephemeral timers/state, start-on-demand + rehydrate when an event arrives with no
  live monitor. ets stays as a read cache only.
- **Planner executes as a bridge task** (Fable MCP + repo tree are Mac-local).
  Fallback chain: bridge planner timeout → server-side Sol/API call over a
  `git ls-files` tree uploaded at run start → lead-self-plan.
- **Usage-limit failover restarts the row fresh** on the fallback provider (row +
  contracts prompt); no mid-task context handoff.
- **Ask-sheet-before-dispatch** must ride the claim-release fix (present-claim
  leak); timeout→planner-default is mandatory so a run never blocks on a sheet.

## Implementation phases

- **P1 server** — classify gate + route (replace group_default_parallel),
  tiers: chat/simple/complex; heuristics first, Haiku call behind a flag.
- **P2 server+bridge** — planner call (advisor task via bridge), structured plan
  schema, plan-driven dispatch (scoped prompts, effort budgets, fallbacks).
- **P3 server** — TeamRunMonitor GenServer: state machine, stall/crash/limit
  interventions, gap rounds, verify dispatch, summary dispatch.
- **P4 iOS** — new node statuses + phase labels + summary settle (delta on
  shipped teamWorkersStatus/progress-node UI).
- **P5 prompts** — worker/integrator prompt templates aligned to task rows
  (the 2026-07-12 prompt upgrades are the base; tighten to row-scoped form).

Each phase ships standalone; earlier phases degrade gracefully to today's flow.

## Implemented 2026-07-12 (P1–P5 initial cut)

- `Vibe.AI.TeamRunMonitor` + Registry + DynamicSupervisor (application tree);
  hooks in register / spawn / progress / settle / cancel paths. Stall 300s
  (240s first-frame grace), retry 1/row within a 3/run budget, usage-limit →
  fresh reassign preferring the plan row's `fallback`, lead exempt, finalize on
  all-terminal. Monitor `init` returns `:ignore` for non-supervisor runs.
- Lead phased protocol (classify → `VIBE_TEAM_PLAN:` JSON → foundation →
  `VIBE_TEAM_SPAWN` → integrate/verify → summary); channel validates plans
  (roster, non-empty disjoint-ish files; overlap warn-only) and stores them in
  ets + `TeamRun.bridge_metadata["teamPlan"]`; spawn dispatches row-scoped
  focus (objective+files+boundaries+contracts); solo plans suppress spawns.
- Hardening from completion review: stale-settle task_id guard in the deliver
  path; stall-retry re-checks durable status; retry/reassign focus falls back
  to the plan row when no stored focus; bridge admission queue
  (`VIBE_MAX_CONCURRENT_TASKS`, default 6) with tagged queued heartbeats and a
  30-min queue-age cap in the monitor (wedged-queue guard).
- iOS: `reassigned`/`cancelled` chip states + `teamPhaseLabel`
  (Planning… / Team building · N working / Verifying…).
- Bridge instruction templates: New-Project Build Standard + lead duties;
  `agy` UI-advisor flag fixed to `--dangerously-skip-permissions`.

## Deferred (recorded, not lost)

- Server startup/periodic sweep finalizing orphaned `running` TeamRun rows
  (deploy-during-quiet-window until then; monitors re-arm on the next event).
- `git ls-files` tree upload at run start for server-side fallback planning.
- Cheap chat-mode replies for plain-group-message fan-out (replacing 4 full
  CLI spawns for chit-chat without dropping the 4-reply UX).
- Verify-stage gap rounds driven by the monitor (today the lead handles gap
  respawns itself via a second VIBE_TEAM_SPAWN).
