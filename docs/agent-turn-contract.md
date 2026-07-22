# Agent turn and finalized-output contract

This document defines how Vibe maps a provider's durable turn records and tool
results into chat delivery. It extends, and does not replace,
`vibe.content.v1`. Rich provider content continues to use that envelope in
message metadata.

## Local Codex evidence

The local Codex session store is an append-only JSONL stream. The bridge code in
this repository consumes the following observed records:

- `session_meta` identifies the persistent session and working directory.
- `turn_context` records the per-turn model, reasoning configuration, and other
  current-turn context.
- Ordered `response_item` records contain assistant messages and tool activity.
  Tool requests (`function_call` or `custom_tool_call`) and their
  `function_call_output` / `custom_tool_call_output` records share `call_id`.
- `task_complete` seals a successful turn; `turn_aborted` seals an interrupted
  one. Completion is a lifecycle fact, separate from the last text item.

Codex's `exec --json` view uses `thread.started`, ordered `item.started` /
`item.completed` events, and `turn.completed`. The session JSONL and exec stream
are two views of the same important invariants: persistent session identity,
one bounded turn, ordered response items, request/result correlation, and an
explicit terminal record.

## Vibe mapping

Vibe keeps its runtime lifecycle under `vibe.agentic.v1`:

1. A persistent thread or conversation owns multiple turns/runs.
2. A turn contains ordered text, tool request, and tool result items.
3. Every tool request and result carries the same call id.
4. A run becomes terminal as `completed`, `failed`, `interrupted`, or
   `waiting_for_user`.

`waiting_for_user` is terminal. `ask_user` returns immediately with a unique
`requestId`, normalized questions, and a text fallback. No BEAM process waits;
the user's answer starts a new turn. If a provider emits `ask_user` beside other
tool calls, Vibe executes only the question call and ends the turn, so no sibling
mutation can run speculatively while required input is missing.

Standalone invoke responses also carry `status` (`completed` or
`waiting_for_user`) and `agent_turn_id`; the same turn id is copied into every
finalized output part.

The finalized chat response remains `vibe.content.v1` plus message metadata.
Each output in one response batch carries:

| Field | Meaning |
| --- | --- |
| `agentTurnId` | Turn shared by every response part. |
| `agentBatchId` | Finalized delivery batch shared by every part. |
| `agentPartId` | Unique identifier for one immutable part. |
| `agentPartIndex` | Zero-based display and persistence order. |
| `agentPartCount` | Total parts, including final text. |
| `agentPartKind` | `text`, `question`, `music`, `image`, `file`, or another supported type. |
| `agentFinalized` | Always `true` for delivered batch parts. |

One base millisecond timestamp plus `agentPartIndex` is used for stored and
broadcast rows, so equal-speed inserts cannot reorder a batch.

## Ordering and examples

Text is always the first finalized part. Rich parts follow in tool-result order;
multiple music tracks preserve search order and therefore become the player
queue in that same order.

```json
[
  {
    "type": "text",
    "text": "Here you go.",
    "metadata": {
      "agentBatchId": "batch-1",
      "agentPartIndex": 0,
      "agentPartCount": 3,
      "agentPartKind": "text",
      "agentFinalized": true
    }
  },
  {
    "type": "music",
    "mediaUrl": "/api/music/stream/video-a",
    "metadata": {
      "videoId": "video-a",
      "trackId": "video-a",
      "title": "First track",
      "artist": "Artist",
      "album": null,
      "duration": "3:05",
      "durationSeconds": 185,
      "cover": "https://example.test/cover-a.jpg",
      "source": "youtube",
      "links": {},
      "agentBatchId": "batch-1",
      "agentPartIndex": 1,
      "agentPartCount": 3,
      "agentPartKind": "music",
      "agentFinalized": true
    }
  }
]
```

The question input and finalized result use this shape:

```json
{
  "questions": [
    {
      "question": "Which room should I use?",
      "header": "Room",
      "multiSelect": false,
      "options": [
        {"label": "General", "description": "The main room"},
        {"label": "Alerts", "description": "Only alerts"}
      ]
    }
  ]
}
```

The result adds `requestId`, `status: "waiting_for_user"`, normalized
`questions`, and `fallbackText`. Its rich output is `type: "question"`; the
fallback remains readable by clients that do not render the question UI.

## Security rules

- Agent configuration and room mutations resolve the agent with both
  `agent_id` and `requester_user_id`. A runtime sender id alone is never an
  ownership credential.
- The requester must equal `agent.owner_user_id`. A channel subscriber cannot
  change prompt/tools/output modes, create rooms as the owner, or attach the
  agent.
- Group attachment adds the agent's shadow user. Channel attachment uses the
  channel-agent assignment policy and its effective tool/output intersections.
- Immediate and scheduled channel posts are attributed to the attached agent's
  shadow user, after verifying both human ownership/admin access and the active
  `agent_admin` attachment.
- Tool self-management is registry-allowlisted. Only explicit sample web/music
  searches may execute during a tool test. Mutation and destructive tools
  return validated dry-run capability data and never dispatch recursively.

## Client invariants

- Never insert rich artifacts into a mutable streaming text row.
- Standalone/channel agents publish only a finalized batch.
- Built-in Vibe AI may stream one text row. After text finalization it emits at
  most one `rich_outputs` event containing ordered non-text outputs, then
  `done`.
- Do not duplicate the text item from `rich_outputs`; its part index is reserved
  in batch metadata even though the existing streamed text row already renders
  it.
- Use `agentBatchId` and `agentPartId` for deduplication, and
  `agentPartIndex` for display order.
- A `music` part's `mediaUrl` is playable. Prefer `preview_url`; otherwise use
  `/api/music/stream/:videoId`. Preserve all tracks for queue/autonext.
- Unknown rich types degrade to their text fallback. Existing
  `vibe.content.v1` parsing remains authoritative for provider content.
