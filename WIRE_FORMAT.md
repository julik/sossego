# Sossego Wire Format

*Specification · revision 4 · 18 Oct 2026*

The frames a Sossego server writes and a Sossego client reads, what is stored, which names are reserved, how events are numbered, and what each side may assume about the other. Applies to the `sossego` gem and its JavaScript client.

## 1. Terms

- **Stream.** An ordered, append-only sequence of events identified by a string, e.g. `account:42:inbox`. Called `sid` on the wire, `stream_id` in storage and code.
- **Event.** One stored row of a stream.
- **Cursor.** An event's row `id`. Global across streams, increasing in commit order within a stream, never reused. Called `seq` on the wire. It is what a client resumes from.
- **Stream sequence.** An event's position within its stream, `sseq`. Dense among retained rows, starting at 1. Used for strict ordering, gap detection and conditional appends. Never a cursor.
- **Head.** The cursor of a stream's newest retained event at the moment a frame is written, or the counter's current value when the stream has none. A lag hint, never used for correctness.
- **Frame.** One SSE message on the wire: an `event:` line, an optional `id:` line, one or more `data:` lines, a blank line.
- **App event.** An event whose name the application chose. Always carried in a `sossego` frame.
- **Transport frame.** A frame the substrate itself emits under a reserved SSE name: `ping` or `close`.
- **Envelope.** The JSON object in a frame's `data:` text.
- **`pld`.** The application's value inside the envelope. The substrate never interprets it.

## 2. SSE event names

> The SSE `event:` field carries only names the substrate owns. Application event names never appear there; they travel as `evt` inside the envelope of a `sossego` frame.

| SSE name | Meaning | Has `id:` | Stored |
|---|---|---|---|
| `sossego` | One app event | Yes, the cursor | Yes |
| `ping` | Liveness. Carries the head and server time | No | Never |
| `close` | The stream is over for this client; do not reconnect | Only when stored | Only through the transport API (section 7) |

### Reserved names

`Sossego::RESERVED_EVENT_NAMES` is `sossego`, `ping`, `close`, `open`, `error`, `message`. The first three are the substrate's. The last three are what the browser's `EventSource` fires on its own; the substrate never uses them for a transport frame either.

The SSE specification reserves nothing; the reservation is Sossego's, enforced on the Ruby side: `Stream#publish` and `Event.publish` raise `Sossego::ReservedEventName` for any name in the set. Only the transport API may store a row under a reserved name, and only for `close`.

## 3. Numbering

> Two counters, two jobs. The cursor (`id`, wire `seq`) says where a client is and is global. The stream sequence (`sseq`) says what order events have inside one stream and is local. A client resumes by cursor and reasons about order and gaps by stream sequence.

### The cursor

- It is the row's primary key. The substrate requires one property of it: within a stream, `id` increases in commit order. It need not be dense, and it is shared across all streams.
- A `bigserial` primary key meets the property under the publish lock in section 7.
- A UUID primary key meets it only when the value is generated at insert time, inside the publish lock, by a time-ordered generator with sub-millisecond monotonicity. PostgreSQL 18's `uuidv7()` as the column default qualifies. `gen_random_uuid()` does not, and neither does a UUIDv7 produced in application code before the lock is taken.
- On the wire the cursor is a string: `"119"` for a bigint host, a 36-character lowercase UUID for a UUID host. JSON numbers above 2^53 are unsafe in JavaScript, so this holds for bigint hosts too.
- Clients compare cursors with one rule: a shorter string is smaller; equal lengths compare lexicographically. This is correct for decimal integers without leading zeros and for fixed-width lowercase UUIDs. A stream never mixes the two. Ruby never parses a cursor; it only places it in `WHERE id > ?`.
- Because the counter never resets, a stream with no retained rows is an ordinary stream: its head is the counter's current value and any future row sorts above every cursor ever issued.

### The stream sequence

- Dense among retained rows of a stream, starting at 1. Assigned as `MAX(sseq) + 1` under the publish lock, so within a stream `sseq` order, `id` order and commit order are the same order.
- It resets to 1 when a stream has been pruned empty. That is harmless because it is never a cursor and never an `id:` line.
- A client reading events in order decides gaps from it alone: consecutive means nothing missed; a jump means rows were pruned or skipped; a decrease means the stream was reset while the client was away, which it treats as a gap.
- A publisher may name the predecessor it expects: `after: n` appends only if the stream's current `sseq` is `n`, and `after: 0` only if the stream has no retained events. Otherwise `Sossego::Conflict`. There is no silent retry.

## 4. The envelope

> The `data:` text of every frame, transport frames included, is one JSON object. It may span several `data:` lines; the browser joins them with `\n`, which JSON tolerates. There is no prefix, no version field, and no other encoding of the outer object.

| Key | Type | Present on | Meaning |
|---|---|---|---|
| `fmt` | string | every frame | How to turn `pld` into a value. See section 5. |
| `evt` | string | every frame | The event name. On a `sossego` frame the application's `event_name`; on a transport frame equal to the SSE name. |
| `seq` | string | frames with a position | The cursor. Same value as the `id:` line. |
| `sseq` | integer | frames with a position | The stream sequence. |
| `head` | string | frames with a position, and `ping` | The stream's head cursor when the frame was written. |
| `sid` | string | frames with a position | The stream id. |
| `pld` | any JSON value, or a string when `fmt` says so | every frame | The payload. |

- Keys are written in the order above so `fmt` and `evt` show first in dev tools. Readers must not depend on order.
- Keys not listed are ignored by readers. Keys listed as present on a frame kind are required there; a reader may raise on their absence.
- A frame without a position (a `ping`, or a `close` that was not stored) has no `seq`, `sseq`, `sid` and no `id:` line, so the browser keeps its last event id.

## 5. `fmt`: payload encodings

`fmt` describes `pld` and nothing else. Because the outer object must already be parsed before `fmt` can be read, `fmt` can never describe the frame as a whole.

| `fmt` | `pld` on the wire | Value handed to the application |
|---|---|---|
| `ejson` | Any JSON value, embedded | That value, as parsed |
| `text` | A JSON string | That string |
| `bytes` | A string: base64 of the bytes | The bytes (`Uint8Array` in the client, a binary `String` in Ruby) |
| `gz:ejson` | A string: base64 of the gzipped JSON text of the value | That value, as parsed |
| `gz:text` | A string: base64 of the gzipped UTF-8 text | That string |
| `gz:bytes` | A string: base64 of the gzipped bytes | The bytes |

- `fmt` says what the published value *is* (a JSON value, text, bytes) and, with the `gz:` prefix, that it travels gzipped. Both sides register all six.
- The kind is fixed at publish and stored with the row (section 7): `text` for a String, `ejson` for anything else, unless the publisher names a `fmt`. Bytes are never guessed from a String's encoding; they are published with `fmt: "bytes"`. Nothing is inferred from the content of a String, so text that looks like JSON stays text.
- Gzip is chosen at publish (`fmt: "gz:text"`, stored compressed) or when a frame is written: a body with `compress_above_bytes` turns an `ejson`, `text` or `bytes` row whose `pld` is at least that many bytes of JSON into its `gz:` variant. A row stored with a `gz:` fmt goes out as stored.
- Encodings are a registry on both sides: `Sossego.encoders[fmt]` and `Sossego.decoders[fmt]` in Ruby, `registerPayloadDecoder(fmt, fn)` in the client. A new encoding is a registry entry on both sides, not a wire change. The server writes only formats it has an encoder for.
- A client decoder may be asynchronous (gzip in browsers is, through `DecompressionStream`); the client still delivers frames in wire order.
- An unknown or missing `fmt` is an error on both sides. Neither side guesses.
- Transport frames (`ping`, `close`) are always `ejson`.

## 6. Frames

### 6.1 `retry:`

The first thing a served connection receives is the standard SSE `retry:` field, in milliseconds. The value may differ per connection.

```
retry: 3417
```

### 6.2 `sossego`: an app event

```
event: sossego
id: 119
data: {
data:   "fmt": "ejson",
data:   "evt": "inbox_changed",
data:   "seq": "119",
data:   "sseq": 57,
data:   "head": "119",
data:   "sid": "account:42:inbox",
data:   "pld": {}
data: }
```

- Emitted for every stored row with a non-reserved `event_name`, in `id` order, starting after the client's cursor.
- `id:` is the cursor. The browser echoes it as `Last-Event-ID`; a client that reopens by hand sends it as `?last_event_id=`.
- The client decodes these one at a time and hands them to the application in wire order, even when a `pld` decoder is asynchronous. It does not wait for the application's handler to finish before handing over the next one.

### 6.3 `ping`: liveness

```
event: ping
data: {
data:   "fmt": "ejson",
data:   "evt": "ping",
data:   "head": "118",
data:   "pld": {"head": "118", "time": "2026-10-02T09:00:00Z"}
data: }
```

- Never stored, never has an `id:`, never moves the cursor.
- Emitted as the first frame after `retry:` when the server is configured to, and after every quiet interval.
- The client resets its stall timer on arrival, before decoding. Pings bypass the ordered queue.

### 6.4 `close`: the stream is over

**Refusal.** Not stored, no position, the entire response body, HTTP 200 with the streaming headers.

```
event: close
data: {"fmt": "ejson", "evt": "close", "pld": {"reason": "flag_off"}}
```

Reasons the substrate defines: `over_budget`. Reasons the hosting controller defines are its own.

**Stored close.** The application ended the stream through the transport API. It has a position and is replayed to a client that reconnects from before it.

```
event: close
id: 31
data: {
data:   "fmt": "ejson",
data:   "evt": "close",
data:   "seq": "31",
data:   "sseq": 12,
data:   "head": "31",
data:   "sid": "task:k7p2qd9z:progress",
data:   "pld": {"reason": "finished"}
data: }
```

- The server body stops iterating after writing a `close` of either form.
- The client handles `close` through the ordered queue, after every `sossego` frame received before it; then closes the `EventSource`, cancels any pending reopen, reports `onClose(reason, seq | null)`, and never reconnects. The end of the HTTP response that follows is not reported as an error.
- There is no other way to end a stream from the table. No app event is terminal.
- A stored close is for streams that belong to one piece of work: a one-off task with progress, a wizard step, a generation that completes. A stream a page reuses for several tasks is not closed, since nothing published after the close is ever read.

## 7. Storage and the Ruby API

### Table `sossego_events`

| Column | Type | Notes |
|---|---|---|
| `id` | bigserial on PostgreSQL, `INTEGER PRIMARY KEY AUTOINCREMENT` on SQLite (or UUID, see section 3) | The cursor. Primary key. Never reused |
| `stream_id` | string, not null | |
| `sseq` | bigint, not null | Dense among retained rows. Unique index on `(stream_id, sseq)` as a guard against a writer that bypassed the lock |
| `event_name` | string, not null | App event name, or `close` when written by the transport API. Validation rejects every other reserved name, and `close` unless the transport API set it |
| `fmt` | string, not null, default `ejson` | What `payload` holds, named as on the wire (section 5). Rows from before the column read as `ejson` |
| `payload` | text, not null | The `pld` in wire form: JSON text for `ejson`, the text itself for `text`, base64 for `bytes` and every `gz:` format. Never queried into. An `ejson` row whose payload does not parse is sent as `text` |
| `created_at` | datetime, not null | Indexed. Retention only |

Indexes: primary key; `(stream_id, id)` for the poll; `(stream_id, sseq)` unique; `created_at`. No `seq` column: the cursor is `id`. No `updated_at`.

### Publishing

```
BEGIN
SET LOCAL lock_timeout = ...                                          -- the bound on a publish
SELECT pg_advisory_xact_lock(hashtext(stream_id))                     -- serializes this stream's publishers
SELECT COALESCE(MAX(sseq), 0) FROM sossego_events WHERE stream_id = ? -- current
raise Sossego::Conflict  if after: was given and after != current
INSERT (stream_id, sseq = current + 1, event_name, fmt, payload, created_at)  -- id by column default
COMMIT                                                                -- releases the lock
```

On SQLite there is no advisory lock: the database has one write lock, and Rails 8 begins transactions with `BEGIN IMMEDIATE`, so the `MAX` read already holds it and commits happen in id order across all streams. The wait is bounded by the connection's busy `timeout:` (then `ActiveRecord::StatementTimeout`). The head of an empty stream is read from `sqlite_sequence`. Other adapters are not supported yet; publishing raises `NotImplementedError`.

- No retry anywhere. The lock means the `MAX` read sees every earlier commit of the stream and the insert cannot collide. Under PgBouncer transaction pooling the transaction-scoped lock is safe.
- The lock is what makes `id` order equal commit order within a stream. Without it a later id can commit first and a connected poller would skip the earlier one for good.
- Under a bigint primary key the id is assigned by the sequence inside the lock. Under a UUID key the column default must generate it inside the lock as well.
- On PostgreSQL the bound is `Sossego::Event.lock_timeout_ms` (default 1000). Past it the publish raises `ActiveRecord::LockWaitTimeout` and writes nothing.

```ruby
# App events. Raises Sossego::ReservedEventName before any query.
stream.publish("inbox_changed", {})
stream.publish("progress", "Queued…", after: 3)          # Sossego::Conflict if sseq is not 3
stream.publish("progress_finished")                      # payload defaults to nil (ejson null)
stream.publish("thumbnail", png_bytes, fmt: :bytes)
stream.publish("turbo_stream", html, fmt: "gz:text")     # stored gzipped
Sossego::Event.publish(stream_id:, event_name:, payload:, after: nil, fmt: nil)

# The transport API: the one way to store a close.
stream.publish_close(reason: "finished")
```

### Reading

- **Poll:** `WHERE stream_id = ? AND id > ? ORDER BY id LIMIT n`.
- **Head:** `MAX(id) WHERE stream_id = ?`, or the sequence's current value when the stream has no rows.
- **Backlog bound:** the start cursor for a connection with none is the head; a cursor with more than `n` retained rows after it is moved to the id of the row just before the `n` newest (`ORDER BY id DESC OFFSET n LIMIT 1`), so exactly `n` are replayed.
- **Prune:** `DELETE WHERE created_at < cutoff`, in batches. Nothing is kept back.

### Writing frames

```ruby
Sossego.envelope(fmt: DEFAULT_FMT, evt:, pld:, seq: nil, sseq: nil, head: nil, sid: nil, encoded: false)
Sossego.format_frame(sse_event:, envelope:, id: nil)
Sossego.format_event_frame(event, head:, sid:)       # event.pld already in wire form
Sossego.format_ping_frame(head:, time: Time.current)
Sossego.format_close_frame(reason:, seq: nil, sseq: nil, head: nil, sid: nil)
Sossego.encoders / Sossego.decoders
Sossego.decode_frame(data_text)
```

## 8. The client

```js
import { createSossegoStream, compareCursors, registerPayloadDecoder, decodeFrame } from "@sossego/client"

const stream = createSossegoStream({
  url: "/inbox_stream?account=42",
  lastEventId: "118",
  events:  { inbox_changed: (payload, event) => { … } },                 // by event name
  onEvent: ({ eventName, seq, sseq, head, streamId, payload }) => { … },  // every event; seq, head are strings
  onGap:   (event, expectedSseq) => { … },                                // before an event that skipped
  onPing:  ({ head, time }) => { … },
  onClose: (reason, seq) => { … },                                        // seq null for a refusal
  onError: (err) => { … },
})

compareCursors(a, b)   // length first, then lexicographic; the only way cursors are compared
registerPayloadDecoder("ejson", (pld) => pld)
decodeFrame(raw)       // => { fmt, evt, seq?, sseq?, head?, sid?, pld } with pld decoded
```

- Exactly three listeners: `sossego`, `ping`, `close`. Never an application event name.
- Every `data:` text goes through `decodeFrame`. `sossego` and `close` frames enter the sequential queue; `ping` does not.
- Cursors are opaque strings compared only with `compareCursors`. Never `Number()`, never `Math.max`.
- Gaps are decided from `sseq`: the client remembers the last `sseq` it delivered per stream; the next event's `sseq` being anything other than that plus one is a gap, reported to `onGap` before the event. A stream's first event, with no remembered `sseq`, is not a gap.
- Routing by `eventName` is the client's `events` option, or the application's own code in `onEvent`.
- Connection errors are handled after the frames received before them, so a refusal's response ending is never reported as a failure.

## 9. Compatibility rules

> No versioning. Not of the envelope, not of `pld`. When a payload's shape changes, the client is responsible for handling both the old and the new shape. Full stop.

- Readers ignore envelope keys they do not know and raise on a missing required key.
- Readers raise on an unknown or missing `fmt`.
- A `sossego` frame with an unknown `evt` is delivered to the application unchanged.
- A transport frame under an SSE name the client does not register is dropped by the browser. Adding a transport frame kind is a client change first, server change second.
- Cursors reveal the global publish rate to every client, as any sequential id does. Hosts for whom that matters use UUIDv7 ids.
- The server guarantees replay only within the configured backlog and retention. The client learns of anything beyond that from `sseq`.

## 10. One served connection, end to end

```
retry: 3417

event: ping
data: {"fmt": "ejson", "evt": "ping", "head": "118", "pld": {"head": "118", "time": "2026-10-02T09:00:00Z"}}

event: sossego
id: 119
data: {"fmt": "ejson", "evt": "inbox_changed", "seq": "119", "sseq": 57, "head": "120", "sid": "account:42:inbox", "pld": {}}

event: sossego
id: 120
data: {"fmt": "ejson", "evt": "brief_ready", "seq": "120", "sseq": 58, "head": "120", "sid": "account:42:inbox",
data:  "pld": {"type": "brief_ready", "chat_id": 7, "chat_created": false}}

event: ping
data: {"fmt": "ejson", "evt": "ping", "head": "120", "pld": {"head": "120", "time": "2026-10-02T09:00:10Z"}}

# 30 s after connect the server ends the response; the browser reconnects after retry
# with Last-Event-ID: 120 and the next connection resumes above it.
```

Envelopes above are shown compactly. On the wire they are pretty-printed, one `data:` line per JSON line, as in section 6. Ids 119 and 120 are consecutive here only because no other stream published in between; that is not a property a reader may rely on.

---

*Revision 4, 18 Oct 2026. Changes from revision 3: `fmt` is stored with each row and fixed at publish; `text`, `bytes` and the `gz:` variants replace `gzjson`; a String is stored as text, as it is.*

*Revision 3, 18 Oct 2026. Changes from revision 2: the `gzjson` encoding; SQLite storage and locking; String payloads are stored as JSON strings; `onGap` in the client; the per-host migration notes moved out of this document.*

*Revision 2, 5 Oct 2026. Changes from revision 1: the cursor is the row id, global and commit-ordered per stream, a string on the wire; `sseq` added as the dense per-stream sequence with `after:` conditional appends; publish serialized by a per-stream advisory lock with no retry; prune keeps nothing; gaps decided from `sseq`; UUID hosts must use an insert-time, time-ordered generator.*
