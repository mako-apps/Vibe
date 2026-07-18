# Task: ChatListView scroll-back trigger + prepend (view side)

You are implementing the VIEW half of scroll-back pagination for the iOS app.
A second agent is implementing the ENGINE half in `ios/ChatModule/ChatEngine.swift`
against the exact contract below — code against it even though it may not exist in
the file yet (do NOT edit ChatEngine yourself).

## Files you may edit (ONLY this)
- `ios/ChatModule/ChatListView.swift`

Do NOT edit ChatEngine.swift, ChatMessageStore.swift, or any other file. Do NOT
commit. Do NOT run the app.

## Engine contract (being added by the other agent — call these exactly)

```swift
// ChatEngine.shared:
func hasOlderChatHistory(chatId: String) -> Bool        // cheap, any thread
@discardableResult
func loadOlderChatHistory(chatId: String) -> Bool       // true = load started/served
```

When a page lands, the engine merges older rows into its history and posts the
normal `chatRowsReloaded` change; the bigger transcript then reaches this view
through the standard rows pipeline (`setRows`/`applyRows`) as a payload whose NEW
rows are strictly OLDER than the current first row (a top-prepend).

## What to build

1. **Trigger**: when the user scrolls near the top of the transcript
   (`scrollViewDidScroll` — see the existing `maybeRevealOlderTranscriptRows(offsetY:)`
   hook, which today guards on `windowedTranscriptSourceRows` that is ALWAYS nil —
   dead code you can repurpose or bypass), request one older page:
   - Conditions: `searchQuery.isEmpty`, `currentBridgeProvider == nil` (skip agent
     DMs), a non-empty `engineChatId`, no request already in flight, offsetY within
     ~600pt of the top.
   - THREADING (hard rule): ChatEngine public methods block via an internal
     `syncOnQueue` — NEVER call them synchronously from the main-thread scroll
     callback. Dispatch to `chatListEngineBindingQueue.async { ... }` (already used
     in this file for engine calls), call `hasOlderChatHistory` /
     `loadOlderChatHistory` there, and hop back to main for UI state.
   - Per-chat no-more memory: when `loadOlderChatHistory` returns false and
     `hasOlderChatHistory` is false, stop asking for this chat until the chat id
     changes (reset your flags in `setEngineChatId` alongside the other resets).

2. **Prepend anchoring**: before the grown payload is applied, the existing strict
   prepend path must run so the viewport does not jump — `applyRows` already
   supports it via `requestsNextHistoryRevealPrepend = true` (see the
   `isHistoryRevealPrepend` handling and the `[ChatOpen] history-window PREPEND`
   anchor math). When you fire a request, remember the current FIRST message row
   key + row count (an "expectation"); when a later `setRows`/`applyRows` pass
   arrives whose payload still CONTAINS that remembered key but has new rows ABOVE
   it, set `requestsNextHistoryRevealPrepend = true` for that one application and
   clear the expectation. Make sure an unrelated payload (stream tick, status flip)
   does not consume or wedge the expectation — expire it after ~15s or on chat
   switch.

3. **Spinner**: reuse the existing `cachedHistoryPullIndicator`
   (`showCachedHistoryLoadingIndicator` / `hideCachedHistoryPullIndicator`) — show it
   only if a started load has been in flight for >150ms (store-served pages are
   near-instant and must not flash it), hide it when the prepend applies, on a 10s
   timeout, and on chat switch.

4. Do not disturb: presentation seed/flush machinery, warm transcript restore,
   agent-DM behavior, the group avatar overlay, or the send-morph paths. Keep the
   change tight around the trigger + expectation + indicator.

## Verify

- `xcodebuild -project ios/Vibe.xcodeproj -scheme Vibe -destination 'generic/platform=iOS' build`
  must succeed. Build at most twice — not after every edit. (If ChatEngine doesn't
  yet have the contract methods when you build, note it and make sure YOUR code is
  otherwise complete — the integrator builds the combined result.)
- Add NSLog lines in the existing style, e.g.
  `[ChatOpen] older-history REQUEST chat=… offset=…` and
  `[ChatOpen] older-history PREPEND-ARMED chat=… expected=…`.

## Style
- Match surrounding code exactly (2-space indent, comment voice, NSLog patterns).
- Comments only for non-obvious constraints.
