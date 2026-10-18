# Shared streams: architecture and where to take it

*18 Oct 2026. For building the layer above `createSossegoStream`. Decision E6 in [discrepancies.md](discrepancies.md) was to leave it in Cora for now (`app/javascript/lib/client_push/inboxStreamConnection.ts` and `pages/Inbox/hooks/useInboxLiveUpdates.ts`), and port it when Cora adopts the gem's client. This document is the map for that port and for what comes after.*

## 1. Why a layer above the stream

`createSossegoStream` owns one EventSource. It handles:
- frame decoding;
- wire-order delivery, including async decoders;
- the stall timer, which reopens when no frame arrives for 25 s;
- reopening with backoff after the browser gives up (3–60 s, jittered);
- `onGap` from `sseq`;
- `close` frames.

That is enough when one element owns one stream for its lifetime, as the Stimulus controller does on Moneymaker's task streams.

A real page breaks that assumption in four ways, and Cora hit each of them:

1. **Many consumers, one stream.** Cora's `Inbox/Index` remounts on every view switch, and `Inbox/Focus` listens to the same account stream. If each mount opened its own EventSource, every view switch would reconnect, and every reconnect costs a server thread and replays.
2. **Background tabs.** An open stream holds a Puma thread, via `max_io_threads`, and one of the browser's connections to the origin. A tab left in the background for hours holds both for nothing.
3. **The page has its own cursor.** The server rendered the page as of some head (`inboxStream.seq` in Cora). Whether the page is behind is a question about that rendered cursor against what the stream has since reported. It is not a question about the stream alone.
4. **SSE can be unavailable** even though nothing errors: a buffering proxy, a refused stream, a server over its stream budget. The page needs to notice within seconds and use something else.

The core cannot handle these without knowing about pages, tabs and fallbacks. Hence a layer.

## 2. The layers

```
 server  StreamingBody (ping_first, max_backlog, retry jitter, max_open_streams, refusals)
   │      SSE: sossego / ping / close frames
   ▼
 core    createSossegoStream(url, lastEventId)        — one EventSource, ordered delivery,
   │                                                    stall + backoff, onGap, onClose
   ▼
 shared  registry: url → Entry                         — refcount + linger, hidden-tab close,
   │      subscribe(url, shownSeq, listener)            cursor bookkeeping, gap across reopens,
   │                                                    transport state machine, catch-up owed
   ▼
 page    a hook / controller with a refresh policy     — "am I behind?", debounce vs catch-up,
   │                                                    bounded reload attempts, hand-off reload
   ▼
 app     what an event means (refetch, apply, show a message)
```

The shared layer is the reusable one. The page layer is a pattern: Cora's is tied to Inertia reloads, but the shape (a rendered cursor compared with a known head) applies to any app that renders on the server.

## 3. The shared layer, piece by piece

All of this is in `inboxStreamConnection.ts`. One `Entry` per URL, in a module-level `Map`.

### 3.1 Registry, reference count, linger
- `subscribe(url, shownSeq, listener)` creates the entry on the first subscriber and returns `unsubscribe`.
- When the last subscriber leaves, the entry waits `LINGER_MS` (1 s) before closing. React runs the departing page's cleanup before the arriving page mounts, and the linger bridges that gap, so a view switch keeps the same EventSource.
- A subscriber arriving inside the linger cancels it and updates `shownSeq`.
- When the linger runs out, all state goes, including the cursor and catch-up owed (see 3.6).

### 3.2 Visibility
- On `visibilitychange` to hidden, it starts a `HIDDEN_GRACE_MS` (30 s) timer. When that fires, it closes the stream and sets `hiddenClosed`. The 30 s grace means a quick tab switch doesn't reconnect.
- On visible again, if it closed while hidden, it reopens from `lastEventId ?? shownSeq`. If a fallback cooldown is running, the cooldown decides instead (3.5).
- A page loaded in a background tab gets no `visibilitychange` until it is shown, so `create` calls the handler once at the start.

### 3.3 Cursor bookkeeping
Cursors are strings, compared only with `compareCursors`/`maxCursor`.

| Field | Meaning |
|---|---|
| `shownSeq` | The head the page was rendered at (from props). The cursor to resume from until an event arrives. `""` = none, older than every cursor. |
| `lastEventId` | The id of the last event received. It takes over from `shownSeq` as the reopen cursor. |
| `knownHead` | `maxCursor` of everything seen: `shownSeq` at creation, each event's `seq` and `head`, each ping's `head`. Never lowered. |
| `live` (per event) | `compareCursors(event.seq, knownHead) > 0`, computed before `knownHead` moves: news, not replay. The page debounces news and catches up on replay (section 4). |

Pings matter here. The server's first frame is a ping carrying the head (`ping_first: true`), so a page learns it is behind within one round trip, even when there are no events to replay, for example after `max_backlog` cut the replay short.

### 3.4 Gaps across reopens
- The rule is the same as the core's: an event whose `sseq` is not `lastSseq + 1` is a gap. That covers a jump (pruned, or past `max_backlog`) and a decrease (pruned empty, then restarted). The first event an entry ever receives is not a gap.
- **Difference from the gem core:** Cora keeps `lastSseq` in the entry, so it survives a reopen. The core's `onGap` keeps it per `createSossegoStream` call, so it forgets on every reopen, and a gap at a reopen is never reported. A shared layer built on the gem's core must either keep `lastSseq` itself, as Cora does, or the core needs an option to start from a known one (say `lastSseq` next to `lastEventId`). **The option is the better fix:** it makes the core's `onGap` correct for every reopening wrapper.

### 3.5 Transport state machine
States: `sse` and `fallback`.

```
          frame delivered (ping or event)
   ┌──────────────────────────────────────────────┐
   ▼                                              │
  sse ──(3 strikes in a row, or a close frame)──► fallback
   ▲                                              │  stream closed; one SSE retry
   │                                              │  per cooldown (2–5 min, jittered)
   └──────────── retry delivers a frame ◄─────────┘  any other outcome: cooldown restarts
```

**A strike** is a connection attempt that:
- fails (`onError` with an `Event`, the connection kind; `Error`s are decode and handler errors and don't count) before delivering any frame; or
- is **silent**: no frame within `SILENT_LIMIT_MS` (5 s) of the attempt starting.

Silence is decisive only because the server's first frame is always a ping. Without `ping_first`, a quiet stream would strike itself.

`STRIKE_LIMIT` is 3. A delivered frame resets the count.

**Subtleties the tests pin**, all in `inboxStreamConnection.test.ts` under "fallback":
- **When an attempt starts.** Right after an error, the `connecting` / `reconnecting` status the core reports is the *wait* before the next attempt: the browser's retry delay or the core's backoff, which can be longer than 5 s. It must not be timed. The `errored` flag skips exactly one status report. An attempt the browser starts by itself shows up as `open` with no frame yet, and is timed from there.
- **One strike per attempt.** An attempt that times out and then errors counts once: the error clears the silent timer.
- **The end of a working response is not a failure.** A connection that delivered frames and then ended (the server recycles every 30 s) doesn't strike.
- **The end of a refusal's response is not an error.** The core reports a connection error only after the frames received before it, and stops after a `close`, so a refusal moves to fallback exactly once.
- **Silent attempts are replaced here.** The core reopens failed connections itself. A silent one is still "open", so the layer closes and reopens it.
- **Fallback while hidden.** A cooldown that ends while the document is hidden past the grace period holds its retry until the page is visible again. Becoming visible during a cooldown doesn't retry early.

### 3.6 Catch-up owed
When the layer moves to `fallback`, it records whether the page should refresh once the other transport is connected:
- **True** if SSE had delivered frames, since the page has been without a live transport since then.
- **True** if strikes came before the move, since there was no transport during them.
- **False** after a refusal on a first attempt that delivered nothing. That page is exactly where a page using the other transport would be at load.

The flag belongs to the entry, not the page, so it survives a view switch. `takeCatchUp(url)` returns true at most once per move. It clears when the transport goes back to `sse`.

### 3.7 Signals to subscribers
```
{ type: "event", eventName, seq, payload, live }
{ type: "ping" }                // knownHead already updated
{ type: "gap" }                 // sent before the event that jumped
{ type: "transport" }           // read the state for the new value
```
Plus `getState(url)` returns `{transport, knownHead, delivered, catchUpOwed}`.

The design choice is that signals carry little and state is read on demand, so subscribers can't drift out of sync with the entry.

## 4. The page layer (Cora's `useInboxLiveUpdates`)

The pattern is "render at a cursor, reload while behind":
- **Behind** means `compareCursors(knownHead, shownSeq) > 0`. The server includes the new `seq` in every reload, so a reload moves `shownSeq` forward.
- **Live events** (`live: true`) reload after the caller's debounce, which restarts on each live event (5 s on Index).
- **Catch-up** (a ping reporting a newer head, replayed events, or mounting while already behind) reloads after a fixed 500 ms. Later events never postpone a pending catch-up, and a catch-up never shortens a pending live debounce.
- **Bounded attempts:** at most 3 reloads per `(knownHead, shownSeq)` pair. Inertia drops an async reload when the path changed meanwhile, and a server that never advances must not cause a reload loop.
- **Gap or hand-off:** the page also refreshes whatever reloads don't cover. In Cora that is `brief_ready`, the dock message.
- **Fallback:** the other transport (the WebSocket) is enabled only while the entry's transport is `fallback`. When it first connects, the hook calls `takeCatchUp` and reloads if owed.

What generalizes: a cursor the page was rendered at, a head the stream reports, and a refresh policy with two speeds (debounced news, prompt catch-up). What doesn't: Inertia's reload, `only`, the debounce values, and what `brief_ready` means.

## 5. The server contract it relies on

The shared layer only works against an endpoint configured like Cora's `ClientPush::EventsController`:

| Option | Why the client needs it |
|---|---|
| `ping_first: true` | The silent-attempt rule (3.5) and fast "am I behind" (3.3) |
| `max_backlog: n` | A tab back from a week away replays at most `n` events, then sees a gap. Without it, the replay is the whole retained stream. |
| `retry_ms: 2_000..5_000` | Tabs of a restarted server don't all reconnect in the same instant |
| `max_open_streams` | Over budget, the server refuses with a `close` frame, so the client moves to fallback instead of queueing |
| Refusals as `close` | Moves to fallback immediately, with no strikes |
| Heartbeat every 10 s | Shorter than the core's 25 s stall timer |

The shared API should document these as requirements and check them where it can: for example, warn when the first frame of a connection is not a ping.

## 6. Proposed gem API (when porting)

```js
import { createSharedStreams } from "sossego"

const streams = createSharedStreams({
  lingerMs: 1_000,
  hiddenGraceMs: 30_000,
  silentLimitMs: 5_000,       // requires ping_first on the server
  strikeLimit: 3,
  cooldownMs: [120_000, 300_000],
})

const unsubscribe = streams.subscribe(url, { cursor: renderedHead }, (signal) => { … })
streams.state(url)        // { transport, knownHead, delivered, catchUpOwed } | undefined
streams.takeCatchUp(url)  // boolean, at most once per move to fallback
```

Notes:
- **`createSharedStreams` over module-level state.** Tests get a fresh registry without `_resetForTesting`, and two independent registries can't collide. Export a default instance for convenience.
- **The core gains `lastSseq`** (3.4). The shared layer passes it on each reopen and uses the core's `onGap`.
- **The fallback stays a signal, not a callback that does something.** What "fallback" means is up to the app: Cora enables a WebSocket, another app might poll a JSON endpoint, Moneymaker would show "reload the page".
- **Integrations:**
  - The Stimulus controller gets `data-sossego-shared-value="true"`, which subscribes through the default registry instead of opening its own stream. Several elements on a page can then listen to one stream.
  - `sossego/react` gets `useSharedStream(url, { cursor, onSignal })`.
- **Port the tests as the spec.** `inboxStreamConnection.test.ts` has 49 cases in five groups (shared connection, knownHead, visibility, gaps, fallback), built on `FakeEventSource`, which the gem now ships as `sossego/testing`. Port them before the implementation.

## 7. Where to iterate next

Roughly in order of value.

1. **The browser's connection limit.** Over HTTP/1.1 a browser allows 6 connections per origin, and every open SSE stream holds one. Six tabs of one app, or one page with several streams, starve the app's ordinary requests. HTTP/2 or HTTP/3 lifts the limit, so the first fix is deployment: make sure the edge speaks HTTP/2 to browsers. Document this in the README. The shared layer's per-URL sharing already helps within one tab.
2. **One connection per browser instead of per tab.** Elect a leader tab, through `navigator.locks` or `BroadcastChannel`, to hold the EventSource and fan frames out to the other tabs. A `SharedWorker` could do the same, but Safari's support has been patchy.
   - This divides server threads by the number of open tabs.
   - Visibility rules change: close only when *all* tabs are hidden.
   - Each tab keeps its own `shownSeq` and page layer; only the transport is shared.
   - Hard parts: leader handover without losing frames (the new leader resumes from the last id it broadcast), and keeping wire order across the channel.
3. **Several streams over one connection.** Today a connection serves one `stream_id`. A page that needs `account:42:inbox` and `chat:99:tokens` opens two. A multiplexed endpoint would need:
   - a Source over several streams (`WHERE stream_id IN (…) AND id > ?`);
   - a composite cursor, because `Last-Event-ID` is one string: either one global id cursor, which works since ids are global and commit-ordered per stream, or per-stream cursors encoded in it;
   - authorization per stream.

   The global id cursor makes the simple version cheap: one cursor covers every stream, and `sseq` gives per-stream gap detection. This is probably the biggest lever after HTTP/2.
4. **Server-side fan-out.** Each connection polls on its own, which is fine up to hundreds of connections per process. Beyond that:
   - one poller thread per process (or `LISTEN/NOTIFY` on Postgres) wakes the connections whose stream changed;
   - the body would wait on a condition variable instead of sleeping.

   The pull-based Source contract allows this without touching the body's loop.
5. **Applying events instead of reloading.** Cora's page layer reloads on any event. Its plans (D3/D4 in `docs/plans/2026-06-23-sossego-inbox-revival-plan.md`) move to events that carry rows, applied in order, with `sseq` gaps falling back to a reload. The shared layer is ready for that, since it delivers ordered events with gap signals; the page layer would advance `shownSeq` itself as it applies events.
6. **Cursor in mutation responses.** Cora's D2: a page's own write returns the new head, so the page doesn't reload for an event it caused. This needs the publish to return the event's id to the request, which `publish_after_commit` doesn't today. It could, through a block or a future.

## 8. Where the code is today

| | Location |
|---|---|
| Core client | `app/javascript/sossego.js` (`createSossegoStream`, `onGap`, cursors, decoders) |
| Test helpers | `app/javascript/sossego/testing.js` (`FakeEventSource`, frame builders), as `sossego/testing` |
| Shared layer (to port) | Cora `app/javascript/lib/client_push/inboxStreamConnection.ts` + `.test.ts` |
| Page layer (pattern) | Cora `app/javascript/pages/Inbox/hooks/useInboxLiveUpdates.ts` + `.test.ts` |
| Server options | `lib/sossego/streaming_body.rb`; Cora's endpoint `app/controllers/client_push/events_controller.rb` shows a full configuration |
| Design history | Cora `docs/plans/2026-06-23-sossego-inbox-revival-plan.md`, `docs/plans/2026-10-02-0013-feat-inbox-sse-live-updates-plan.md`, `docs/solutions/best-practices/reconnecting-stream-endpoint-cookies-threads-refusals-20261002.md` |
