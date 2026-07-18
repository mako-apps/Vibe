# Task: ChatEngine older-history pagination (engine + store side)

You are implementing the ENGINE half of scroll-back pagination for the iOS app.
A second agent is implementing the VIEW half in `ios/ChatModule/ChatListView.swift`
against the exact contract below — implement the contract precisely.

## Files you may edit (ONLY these)
- `ios/ChatModule/ChatEngine.swift`
- `ios/ChatModule/ChatMessageStore.swift`

Do NOT edit ChatListView.swift or any other file. Do NOT commit. Do NOT run the app.

## Context

- Server endpoint `GET /api/chat/{chatId}/messages?limit=N&before=<cursor>` already
  supports keyset pagination. Response JSON: `{"messages": [...], "nextCursor":
  "<opaque>", "hasMore": true|false}`. The cursor is
  `base64url(JSON {"timestamp": <ms int>, "id": "<message uuid>"})` without padding —
  the client may CONSTRUCT one locally from any known row (see
  `server/lib/vibe/chat.ex` `decode_history_cursor` for the exact shape; read it).
- `ChatEngine.loadChatHistoryIfNeededLocked` fetches the newest 100 into
  `historyRowsByChat[chatId]` and currently IGNORES `nextCursor`/`hasMore` in
  `applyChatHistoryResponseLocked` — capture them.
- `ChatMessageStore` (SQLite, new today) persists rows per (user, chat, message):
  table `messages(user_id, chat_id, message_id, ts, payload)`. It may hold rows
  OLDER than the in-memory window. It is only ever touched on ChatEngine's serial
  `queue` — keep it that way.
- Threading rule (hard): public ChatEngine methods use `syncOnQueue { ... }` or
  `queue.async`; all `...Locked` funcs run on `queue`. Never post notifications or
  call URLSession completion work outside the queue pattern already used in the file.
  Follow `loadChatHistoryIfNeededLocked` as the reference for fetch structure,
  logging (`NSLog` + `appendJournalLocked`), and pinned URLSession usage.

## Contract to implement (the view half depends on these exact signatures)

```swift
/// True when older transcript pages may exist below the currently-loaded window
/// (local store depth or a live server cursor). Cheap; callable from any thread.
func hasOlderChatHistory(chatId: String) -> Bool

/// Loads ONE older page (~60 rows): store-first, else network with a `before`
/// cursor. Returns true if a load was started (or served synchronously from the
/// store), false when there is nothing to do (no more pages, already loading,
/// agent/volatile surface, saved_messages, empty chatId).
@discardableResult
func loadOlderChatHistory(chatId: String) -> Bool
```

Completion (both store and network paths): merge the older rows into
`historyRowsByChat[chatId]` using the existing merge machinery
(`mergedStoredHistoryRowsLocked` handles union + sort + bubble-sequence shapes),
then `postChangeLocked(reason: "chatRowsReloaded", userInfo: ["chatId": chatId,
"state": statusSnapshotLocked(), "prependedOlder": <count>])`. The view pulls rows
through the normal `getChatRows` pipeline.

## Implementation notes

1. `ChatMessageStore`: add an older-page query, e.g.
   `func olderMessagePayloads(userId:chatId:beforeTs:beforeMessageId:limit:) -> [Data]`
   (`ts < ?` OR (`ts = ?` AND `message_id < ?`), ORDER BY ts DESC LIMIT n, returned
   ascending like `recentMessagePayloads`). Match the existing code style in that file.
2. Engine per-chat state (all touched on `queue` only):
   `historyOlderExhaustedChats: Set<String>`, `historyLoadingOlderChats: Set<String>`,
   and store `hasMore`/`nextCursor` from history responses (e.g.
   `historyHasMoreByChat: [String: Bool]`, `historyNextCursorByChat: [String: String]`).
3. `loadOlderChatHistory` flow on `queue`:
   - Guard: not already loading; not `isBuiltInAgentChatId` / volatile bridge chat /
     `saved_messages`; `historyRowsByChat[chatId]` non-empty.
   - Find the oldest in-memory row that has a messageId (use existing
     `messageId(fromRow:)` / `messageTimestampMs(fromRow:)` helpers).
   - Store-first: query `olderMessagePayloads` (limit 60) below that row. If rows
     come back, decode, filter `isTransientStreamRow`, merge, post, done (fast path,
     fully offline).
   - Else network (only if not exhausted): build cursor
     base64url(`{"timestamp": ts, "id": messageId}`) from the oldest row — prefer the
     server-provided `nextCursor` when the oldest row is the one that fetch returned.
     GET with `limit=60&before=<cursor>`, same headers/pinned session as
     `loadChatHistoryIfNeededLocked`. On response: `buildHistoryRowsLocked`, merge,
     persist to store, update `hasMore` (`hasMore == false` → insert into
     `historyOlderExhaustedChats`), post.
   - Empty page → mark exhausted, post nothing, clear loading flag.
4. Persisting older pages: `persistHistoryRowsToStoreLocked` currently calls
   `messageStore.pruneChat(...)` keeping the newest 1000 — a deep scroll-back must
   NOT have its older pages immediately pruned. Add a `skipPrune`/depth-aware path
   (e.g. prune to `max(1000, currentCount)` or skip prune when persisting an older
   page).
5. `hasOlderChatHistory`: true when NOT exhausted AND (store has rows older than the
   in-memory oldest, OR `hasMore != false`). Cheap store probe is fine (COUNT with
   the same predicate LIMIT 1); wrap in `syncOnQueue`.
6. `applyChatHistoryResponseLocked`: also parse top-level `nextCursor` (string) and
   `hasMore` (bool) when the response is a dict; keep behavior identical otherwise.

## Verify

- `xcodebuild -project ios/Vibe.xcodeproj -scheme Vibe -destination 'generic/platform=iOS' build`
  must succeed. Build at most twice (once mid, once final) — do not build after
  every edit.
- Log lines: follow the existing `[ChatEngine] loadChatHistory ...` NSLog style, e.g.
  `[ChatEngine] loadOlderHistory chatId=… source=store|network rows=N exhausted=Y/N`.

## Style
- Match surrounding code exactly (2-space indent, NSLog patterns, journal events).
- Comments only for non-obvious constraints, in the existing voice.
