# Chat pipeline architecture v2 — single store, delta updates

Status: TARGET (2026-07-16). Staged migration in progress; each stage must leave the
app building and behaviorally stable.

## Why v1 is wrong (the production risk)

Today the same chat transcript has **five independent sources**, reconciled by
byte-equality at render time:

1. Home roster tail (`initialRows` on the route, 16 rows).
2. Warm transcript snapshot (`prewarmWarmTranscriptSnapshot` at launch).
3. Disk store restore (`restoreCachedHistoryRowsLocked` → `historyRowsByChat`).
4. Engine merge of network history (`mergedStoredHistoryRowsLocked`).
5. View-side live overlay (`nativeEngineRowsById` merged in `mergedRowsPayload`).

Any field asymmetry between two sources (example: reply previews, which ride only
live deliveries) makes the post-open "authority flush" see 70+ "changed" rows and
repaint/re-measure them — the measured 154ms post-push stall, opacity flicker and
list shift. Every fix so far patched one asymmetry; the architecture guarantees new
ones. This does not scale to production.

## Target architecture (Telegram model)

**One store. One ingest funnel. Deltas out. Views render, never reconcile.**

```
 history fetch ┐
 channel join  ├─► ingestMessages(chatId, rawRows, source) ──► ChatMessageIndex
 live message  │        (normalize + field-merge policy)        (ordered, per chat)
 edits/deletes │                                                    │
 bridge mirror │                                   persist (SQLite ChatMessageStore)
 optimistic    ┘                                                    │
                                                       ChatDelta {inserted, updated,
                                                                  deleted, generation}
                                                                    │
                                                    ChatListView.applyDelta(…)
```

### Contracts

**C1 — `ingestMessagesLocked(chatId:rows:source:)` (ChatEngine, serial queue).**
The ONLY writer of per-chat message state. Sources: `.history`, `.live`, `.bridge`,
`.optimistic`, `.savedMessages`, `.storeRestore`. Behavior:
- Normalizes every raw payload through the ONE existing normalize path
  (`buildHistoryRowsLocked`'s row shape is canonical).
- Field-merge policy, single place: an incoming copy of an existing message NEVER
  erases a known render-relevant field it does not itself carry (generalizes the
  reply-preview monotone carry). Newer non-nil values win; nil never overwrites.
- Upserts into the ordered index (by timestamp, then id — current sort), applies
  tombstones (`deletedMessageIdsByChat`), applies the existing dedup passes
  (mirrored prompt, persisted-vs-bridge twin, agent shells) — these move here FROM
  `mergedChatRowsLocked` so every consumer sees deduped rows.
- Persists via existing `persistHistoryRowsToStoreLocked` (debounced).

**C2 — `ChatDelta` event.** After each ingest batch, the engine posts ONE change
notification: `{chatId, generation, insertedIds, updatedIds, deletedIds}` where
`updatedIds` contains only messages whose canonical row dict actually changed
(NSDictionary equality — cheap, engine-side). Full-reload notifications remain only
for: initial load, store reset, explicit clear.

**C3 — View consumption.** `ChatListView`:
- Open: ONE synchronous read (`getChatRows`) = the presentation seed (commit-first
  push + reopen snapshot overlay stay exactly as shipped).
- Updates: `applyDelta` — insert/update/delete the named rows only. Repaint
  decision per row stays `chatListRowContentEqual` (render truth).
- The full-array `setRows` path remains ONLY as the initial mount and for
  full-reload events.

### Kill list (deleted when C3 lands, not before)

View (ChatListView/ChatMainView/host):
- `warmTranscriptBaseline*` merge (route-tail vs snapshot union).
- `rowsDeferredUntilPresentation*` + presentation-flush + `pendingPresentationSeed
  Reconcile` machinery (nothing to reconcile when there is one source).
- `nativeEngineRowsById` overlay + `mergedRowsPayload` (live rows come as deltas).
- `sourceRowsPayload` retention plumbing.
- `hydrateRowsFromNativeHistoryIfReady` fast paths (open = one store read).
- Launch `prewarmWarmTranscriptSnapshot` (store read is cheap; parse-reuse and
  disk-height caches stay — they are render caches, not truth).
- View-side copies of dedup filters that moved into C1.

Engine:
- `mergedStoredHistoryRowsLocked` (subsumed by C1 merge policy).
- Duplicate normalize forks (`applySavedMessagesHistoryResponseLocked` feeding a
  parallel shape) — route through C1.

### Invariants (checked in review of every stage)

- I1: the engine serial queue is the only writer; views only read + receive deltas.
- I2: no consumer sees rows that skipped the dedup passes.
- I3: a refetch that changes nothing produces an EMPTY delta (no notification).
- I4: E2E posture unchanged: plaintext stays in the existing store's protection
  class; `agentRuntimeEnc` stays opaque to the server.
- I5: commit-first push, reopen snapshot, disk heights, parse reuse, progressive
  warmup are UNCHANGED by this refactor (they consume the store, they are not truth).

### Stages

- **A1 (engine, additive):** introduce `ingestMessagesLocked` + `ChatDelta` behind
  the existing APIs. `applyChatHistoryResponseLocked`, live message handlers, and
  channel-backlog ingest route through it. Old notifications still fire. Build green.
- **A2 (engine):** all remaining writers rerouted; `mergedChatRowsLocked` reads the
  index; view-overlay inputs become deltas. Build green.
- **B (view):** `applyDelta` consumption; kill list deleted. Build green + device
  smoke test (open/reopen the three test chats, send, receive, team run live tail).
- **C (sweep):** dead-function inventory removal (evidence: zero references outside
  the file, or only from other dead functions). Build green after every batch.

### Non-goals

- No visual/UX changes. No server API changes. No new dependencies.
- Message send path, E2E crypto, bridge protocol: untouched.
