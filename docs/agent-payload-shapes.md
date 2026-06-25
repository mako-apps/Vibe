# Claude & Codex agent payload shapes

Authoritative reference for the real wire shapes Claude Code and Codex emit, and
how they flow through the bridge → server → iOS agent view. Captured from live
session logs on 2026-06-25 (`~/.claude/projects/**/*.jsonl`,
`~/.codex/sessions/**/rollout-*.jsonl`). Build and verify the parsing layer
(bridge `vibe-bridge.js`, server `LocalAgentWorker`, iOS `ChatAgentMessagesView`)
against this — do not guess node shapes.

## Pipeline

```
claude -p --output-format stream-json --verbose   (one JSON object per line)
codex exec --json                                  (one JSON object per line)
        │  raw stdout lines
        ▼
vibe-bridge.js  ── progress {provider, chatId, line} ──▶ server
                ── result   {provider, chatId, output, exitStatus, agentRuntime}
        │
        ▼
LocalAgentWorker.bridge_stream_update / parse_result
   extract_result/2  ⇒ { text, progress_nodes, tool_events, usage }
        │  broadcast "agent-stream" { text, progressNodes, toolEvents, status }
        ▼
iOS ChatEngine → ChatNativeAgentView / ChatAgentMessagesView  (parsed rows)
```

`agent-stream` payload (server → chat topic): `text` (running summary), `progressNodes`,
`toolEvents`, `status` ("running" | "done"). The final `result` carries the full output;
progress lines are capped (`@max_stream_lines 500`) so only the result is authoritative.

---

## Claude (`stream-json`)

One object per line. Live-stream top-level `type`s:

| type | meaning | key fields |
|---|---|---|
| `system` (subtype `init`) | session start | `model`, `tools[]`, `slash_commands[]`, `mcp_servers[]`, `agents[]`, `skills[]`, `session_id`, `permissionMode`, `cwd`, `claude_code_version` |
| `assistant` | model turn | `message.content[]` (blocks below), `message.usage` |
| `user` | tool results fed back | `message.content[]` (`tool_result` blocks) or string |
| `result` | turn end | `usage`, `total_cost_usd`, `duration_ms`, `duration_api_ms`, `ttft_ms`, `num_turns`, `session_id`, `model` |

Session-log-only `type`s (persistence, NOT in live stream — ignore for rendering):
`queue-operation`, `attachment`, `file-history-snapshot`, `last-prompt`, `ai-title`, `mode`.

### Content blocks (`message.content[]`)

```jsonc
{ "type":"text", "text":"…" }
{ "type":"thinking", "thinking":"…", "signature":"…" }          // reasoning
{ "type":"image", "source":{ "type":"base64","media_type":"image/jpeg","data":"…" } }
{ "type":"tool_use", "id":"toolu_…", "name":"Read", "input":{…}, "caller":{"type":"direct"} }
{ "type":"tool_result", "tool_use_id":"toolu_…", "content":"…" | [ {…}, {image} ] }
```

`thinking.thinking` is often empty with only a `signature` (encrypted CoT) — render as a
"Thinking…" node, never show the signature.

### `tool_use.input` keys per tool (drives the verb + detail shown)

| name | input keys | render as |
|---|---|---|
| `Read` | `file_path` | Read `basename` |
| `Edit` | `file_path`, `old_string`, `new_string`, `replace_all` | Edit `basename` `+N −M` (diff old/new) |
| `Write` | `file_path`, `content` | Create `basename` (`N` lines) |
| `Bash` | `command`, `description` | Run `description` (cmd as detail) |
| `TodoWrite` | `todos[]` | Planning (todo list) |
| `WebSearch` | `query` | Search `query` |
| `WebFetch` | `url`, `prompt` | Fetch `host` |
| `Monitor` | `command`, `description`, `timeout_ms`, `persistent` | Run (watch) |
| `ToolSearch` | `query`, `max_results` | Search tools |
| `TaskStop` | `task_id` | — |
| `AskUserQuestion` | `questions[]` | Question |

`tool_result.content` is a string OR a list (text + `image` blocks). Map by `tool_use_id`.

---

## Codex (`codex exec --json`)

> **CRITICAL:** `codex exec --json` **stdout** (what the bridge captures) is the
> *thread-item streaming* format below — NOT the `event_msg`/`response_item` shape
> found in `~/.codex/sessions/**/rollout-*.jsonl`. The rollout files are the
> on-disk persistence format and are never seen by the bridge. Verified 2026-06-25
> against codex-cli **0.142.0** (binary string analysis + live stdout capture).

One JSON object per line. **Envelope** events keyed by top-level `type`:

| type | fields | meaning |
|---|---|---|
| `thread.started` | `thread_id` | session start (use `thread_id` for `--resume` continuity) |
| `turn.started` | — | model turn begins |
| `item.started` | `item` | a thread item begins (status running) |
| `item.updated` | `item` | item progress update |
| `item.completed` | `item` | item finished (status done) |
| `turn.completed` | `usage` | turn done |
| `turn.failed` | `error.message` | turn failed (e.g. usage-limit) |
| `error` | `message` | top-level error (e.g. "You've hit your usage limit") |

The real work is in the **`item`** object (`event["item"]`). Discriminator is
`item_type` (fall back to `type`). Item types (from the 0.142.0 binary):

| item_type | key fields | maps to |
|---|---|---|
| `agent_message` | `text` | **summary text** (the assistant's reply) |
| `reasoning` | `text` | Thinking node |
| `command_execution` | `command` (string), `aggregated_output`, `exit_code`, `status`, `duration` | Run (Bash); `exit_code != 0` ⇒ failed |
| `file_change` | `changes[]` = `{path, kind: add\|delete\|update}`, `status` | Edit/Create (no inline diff counts in stream) |
| `mcp_tool_call` | `server`, `tool`, `arguments`, `status`, `result` | Tool |
| `web_search` | `query`, `action` | Search |
| `todo_list` | `items[]` | Planning |
| `error` | `message` | error node |

Item `status` values: `pending_init`, `in_progress`/`running`, `completed`,
`interrupted`, `errored`, `failed`, `not_found`. Final status comes from the
envelope (`item.completed` ⇒ done) combined with `item.status` and, for
`command_execution`, `exit_code`. Correlate `item.started` ↔ `item.completed`
by `item.id` (the worker merges same-id events).

Common failure surfaced to the user: top-level `{"type":"error","message":"You've
hit your usage limit…"}` followed by `turn.failed` — that's a Codex quota cap, not
a parse error. The worker maps the message to the visible result text.

---

## Rendering contract (iOS agent view)

`ChatAgentMessagesView` already understands these row kinds — wire the parsed nodes to them:
- progress verbs: `read`, `edit`, `write`, `bash`, `search`, `web`, `task`, `todo`
- statuses: `running`, `done`/`complete`/`success`, `error`/`failed`
- row message types: `agent_progress`, `agent_progress_tree`, `agent_actions`, `agent_card`

Default chat view shows the **summary** (`agent_message` / Claude final `text`) as a bubble;
the full progress/thinking/tool/patch nodes render in the **agent view** (solid bg). Each agent
bubble in the default view gets a compact "view agent" affordance that pushes the agent view.
