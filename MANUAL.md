# Sossego manual

The [README](README.md) gets you running with Turbo and Stimulus. This is everything else.

- [How it works](#how-it-works)
- [How events are stored](#how-events-are-stored)
- [Publishing](#publishing)
- [Serving streams](#serving-streams)
- [Configuration](#configuration)
- [Background jobs](#background-jobs)
- [Getting the JavaScript into your app](#getting-the-javascript-into-your-app)
- [The JavaScript client](#the-javascript-client)
- [Stimulus](#stimulus)
- [Handling your own events](#handling-your-own-events)
- [Using with React](#using-with-react)
- [Testing your app](#testing-your-app)
- [Why SSE and not \<something\>Cable](#why-sse-and-not-somethingcable)

## How it works

A **stream** is a name, like `account:42:inbox`, and the ordered list of **events** published to it. Publishing an event inserts a row. A browser opens the stream with `EventSource`. The server answers with a long response that polls the table every quarter second and writes each new row as a Server-Sent Event. After 30 seconds the server ends the response and the browser reconnects, sending the last event id it saw. The next response continues from there. Nothing is lost while the browser is away, as long as the events are still kept (24 hours by default).

Each event carries two numbers:

- **`seq`, the cursor:** the row's id, sent as a string. Clients resume from it. Ids are shared by all streams, so the cursors of one stream are increasing but not consecutive.
- **`sseq`, the stream sequence:** 1, 2, 3… within one stream. A client that sees `sseq` jump knows it missed events (pruned, or more than the server would replay) and can refetch.

Every frame is one of three SSE event types: `sossego` (one of your events), `ping` (every 10 s of quiet, carrying the stream's newest cursor), or `close` (the stream is over, don't reconnect). Your event names travel inside the frame's JSON. [WIRE_FORMAT.md](WIRE_FORMAT.md) has the details.

## How events are stored

One table, append-only:

```
sossego_events
  id          bigint, primary key  — the cursor; never reused (bigserial / AUTOINCREMENT)
  stream_id   string               — "account:42:inbox"
  sseq        bigint               — 1, 2, 3… per stream; unique with stream_id
  event_name  string               — "inbox_changed", or "close"
  fmt         string               — what payload holds: ejson | text | bytes | gz:ejson | gz:text | gz:bytes
  payload     text                 — the payload in that format
  created_at  datetime             — for pruning
  indexes: (stream_id, id), unique (stream_id, sseq), (created_at)
```

A few rows:

```
 id  | stream_id              | sseq | event_name     | fmt   | payload
-----+------------------------+------+----------------+-------+---------------------------
 118 | account:42:inbox       |  56  | inbox_changed  | ejson | {}
 119 | task:k7p2qd9z:progress |   1  | progress       | text  | Queued...
 120 | account:42:inbox       |  57  | brief_ready    | ejson | {"chat_id":7}
 121 | task:k7p2qd9z:progress |   2  | progress_finished | ejson | null
 122 | task:k7p2qd9z:progress |   3  | close          | ejson | {"reason":"finished"}
```

**Publishing** takes the stream's lock, reads `MAX(sseq)`, inserts `MAX + 1` and commits. The lock makes id order, `sseq` order and commit order the same within a stream, so a poller never skips an event that commits late.
- On PostgreSQL the lock is `pg_advisory_xact_lock(hashtext(stream_id))`, bounded by `Sossego::Event.lock_timeout_ms`.
- On SQLite it is the database's own write lock: Rails 8 opens transactions with `BEGIN IMMEDIATE`.

**Reading** is `WHERE stream_id = ? AND id > cursor ORDER BY id LIMIT 100`, on the `(stream_id, id)` index. The newest cursor of an empty stream is the id counter, so a page that renders an empty stream still gets a cursor that will see the first event.

**Pruning:** `Sossego::PruneJob` deletes rows older than `Sossego.retention`, in batches. Ids never reset, so a stream that was pruned empty carries on, and old cursors stay valid. `sseq` starts over at 1 for such a stream, and the client counts that as a gap.

**Where:** the table is in your app's database unless `Sossego.connects_to` puts it in one of its own (see [Configuration](#configuration)). Publishing in your database means an event can commit, or roll back, with the change it announces.

## Publishing

```ruby
stream = Sossego::Stream.for(account, :inbox)       # "account:42:inbox"
stream = Sossego::Stream.new("anything:you:like")

stream.publish("inbox_changed", {count: 3})          # a Hash, Array, number, nil… goes as JSON (fmt "ejson")
stream.publish("progress", "Halfway there")          # a String goes as text, as it is (fmt "text")
stream.publish("thumbnail", png, fmt: :bytes)        # bytes only when asked for; the client gets a Uint8Array
stream.publish("turbo_stream", html, fmt: "gz:text") # stored and sent gzipped
stream.publish("progress", "Queued", after: 0)       # only if the stream is empty, else Sossego::Conflict
stream.publish("progress", "Step 4", after: 3)       # only if the newest sseq is 3
```

`Stream.for(record, channel)` names the stream `<model name>:<id>:<channel>`. A class can override the first part with `def self.sossego_namespace`.

Event names are yours, except `sossego`, `ping`, `close`, `open`, `error` and `message`, which raise `Sossego::ReservedEventName`.

### Turbo Streams

`publish_turbo_stream` builds a `<turbo-stream>` element and publishes it as a `turbo_stream` event. The `@sossego/stimulus` controller hands it to `Turbo.renderStreamMessage`. It takes the arguments of turbo-rails' `broadcast_action_to`, and turbo-rails isn't needed on the server:

```ruby
stream.publish_turbo_stream(:append, target: "comments", partial: "comments/comment", locals: {comment:})
stream.publish_turbo_stream(:prepend, targets: ".feed", html: "<li>Hi</li>")
stream.publish_turbo_stream(:replace, target: comment, partial: "comments/comment", locals: {comment:},
  attributes: {method: :morph})
stream.publish_turbo_stream(:remove, target: comment)          # a record becomes its dom_id
stream.publish_turbo_stream(:refresh)                           # carries Turbo's request id, so the tab that caused it skips it
stream.publish_turbo_stream(:notify, attributes: {message: "Saved"}, render: false)   # a custom action
```

- **Actions:** any Turbo Stream action. The built-in ones are `append`, `prepend`, `replace`, `update`, `remove`, `before`, `after` and `refresh`. A custom action is just a name. Register it in the browser with `Turbo.StreamActions.notify = function () { … this.getAttribute("message") … }`; its own attributes go in `attributes:`.
- **Template:**
  - `partial:` and `locals:`, `template:` or `renderable:` are rendered by `Sossego.turbo_stream_renderer`, which defaults to `ApplicationController`;
  - `html:` or `content:` is used as it is;
  - `render: false` leaves the template empty;
  - `remove` and `refresh` have no template.
- **Several actions in one event:** pass the elements as strings. `Sossego::TurboStream.tag(action, target:, template:, **attributes)` and `Sossego::TurboStream.render(action, **options)` build them.

```ruby
stream.publish_turbo_stream(Sossego::TurboStream.tag(:remove, target: "spinner"),
                            Sossego::TurboStream.render(:update, target: "total", html: "42"))
```

To publish after the surrounding transaction commits: `stream.publish_after_commit("turbo_stream", Sossego::TurboStream.render(...))`.

### Publishing from inside a transaction

`publish` writes inside the current transaction. If that transaction rolls back, the event goes with it. Until it commits, nobody can see the event. To announce a change only once it is visible, use `publish_after_commit`:

```ruby
Order.transaction do
  order.update!(state: "paid")
  stream.publish_after_commit("order_paid", {id: order.id},
    on_error: ->(error) { Rails.error.report(error, handled: true) })
end
```

It publishes when every open transaction has committed, and doesn't publish on a rollback. With `on_error` a failed publish goes to the callback instead of raising; that suits signals whose loss costs a refetch. In tests that run inside a transaction, it publishes at once.

### Ending a stream

`stream.publish_close(reason: "finished")` ends the stream for every client that reads up to it, and they don't reconnect. Do this for streams that belong to one piece of work: a task with progress, a wizard step, a generation that completes. Don't do it for a stream a page keeps for several tasks: after the close, nobody hears what is published to it.

## Serving streams

A stream your app names is served by a subclass of `Sossego::StreamsController`:

```ruby
class InboxStreamsController < Sossego::StreamsController
  def show
    return refuse_stream("unauthenticated") unless current_user
    @account = current_user.accounts.find_by(id: params[:account])
    super   # refuses with "forbidden" when sossego_stream returns nil
  end

  protected

  def sossego_stream
    Sossego::Stream.for(@account, :inbox) if @account
  end

  def sossego_body_options
    {ping_first: true, max_backlog: 100, max_open_streams: 16, retry_ms: 2_000..5_000}
  end
end
```

It inherits from `ActionController::Base`, not your `ApplicationController`. A stream connect is not a page view, so filters that track visits or switch accounts don't belong on it. Bring the authentication you need.

**Refusals.** An `EventSource` can't read an error status: it sees a failed connection and retries forever. So `refuse_stream(reason)` answers HTTP 200 with one `close` frame. The client stops and is told the reason.

**Sessions.** A stream response never writes the session cookie. Otherwise every reconnect, about every 33 seconds per tab, would write back a session that another request may have changed since, for example by signing out.

**Body options** (`sossego_body_options`):

| Option | Default | What it does |
|---|---|---|
| `ping_first` | false | Send a ping with the newest cursor right away. The client knows at once whether it is behind. |
| `max_backlog` | nil | A connection with no cursor starts at the newest event, and one far behind replays at most this many. Without it, a connection with no cursor replays everything retained. |
| `max_open_streams` | nil | Per process. Over it, refuse with reason `over_budget`. |
| `open_streams_gauge`, `on_over_budget` | nil | Callables for metrics |
| `poll_interval_s` | 0.25 | Sleep between polls that found nothing |
| `retry_ms` | 3000 | The browser's reconnect delay. A Range gives each connection its own value, so the tabs of a restarted server don't all reconnect at once. |
| `compress_above_bytes` | nil | Gzip payloads at least this big on the way out |

**Threads.** An open stream holds a Puma thread for up to 30 seconds. Streams mark themselves IO-bound, so set Puma's `max_io_threads` and they won't take the threads that serve pages. Use the same number for `max_open_streams`. Over HTTP/1.1 a browser opens at most 6 connections per site, and each open stream uses one, so serve over HTTP/2 if pages keep several streams open.

**Signed streams.** The engine serves any stream to a request with a valid signature, at `/sossego/streams/:stream_id?sig=…`. `sossego_signed_stream_path(stream)` and `sossego_signed_stream_url(stream)` build the URL. This suits [one-off streams](README.md#one-off-named-streams), and also a stream you'd rather hand out than authorize per request, as InertiaCable does (see [Using with React](#using-with-react)). These connections replay everything retained, so work started before the page connected is not missed.

## Configuration

`bin/rails generate sossego:install` writes `config/initializers/sossego.rb`. An app upgrading the gem runs it again with `--skip` to get new migrations; its initializer is left alone.

| Setting | Default | |
|---|---|---|
| `Sossego.retention` | 24 hours | How long events are kept. A client away for longer sees a gap. |
| `Sossego.connects_to` | none | Put the table in its own database, like Solid Queue: `{database: {writing: :sossego}}` |
| `Sossego.readonly_sqlite_polling` | true | SQLite: poll through a read-only connection opened for each poll. See below. |
| `Sossego.around_poll` | none | Run each poll on another connection. See below. |
| `Sossego.verifier` | `message_verifier("sossego_streams")` | Signs stream ids for the browser |
| `Sossego.turbo_stream_renderer` | `-> { ApplicationController }` | Renders the templates of `publish_turbo_stream` |
| `Sossego::Event.lock_timeout_ms` | 1000 | PostgreSQL: how long a publish waits for its stream's lock |

**Which connection streams poll on.** On SQLite, each poll opens the database file read-only, with the main connection's settings, and closes it once the poll is done. A stream never holds a connection between polls and can never take the write lock. Polls use the main connection instead in two cases: when Rails has pinned a connection for a transactional test, whose rows a separate connection couldn't see, and when the polling thread is itself inside a transaction. `Sossego.readonly_sqlite_polling = false` turns this off.

On other databases each poll borrows the connection your app gives `Sossego::Event` and returns it at once. To poll somewhere else, wrap the poll:

```ruby
# a reading role (a replica), declared in database.yml
Sossego.around_poll = ->(poll) { Sossego.connection_class.connected_to(role: :reading) { poll.call } }
```

`around_poll`, when set, is used on SQLite too, instead of the read-only connection.

A UUID primary key works if ids are generated in commit order (PostgreSQL 18's `uuidv7()` as the column default). Override `Sossego::Event.cursor_valid?` to accept them.

## Background jobs

Every `Sossego::Stream` has helpers for the events the Stimulus controller handles. Jobs, controllers and callbacks all publish through a stream:

| Helper | Event | Payload |
|---|---|---|
| `stream.publish_progress(text)` | `progress` | text |
| `stream.publish_warning(text)` | `progress_warning` | text |
| `stream.publish_error(text)` | `error_message` | text |
| `stream.publish_field_prefill(hash)` | `field_prefill` | `{"model[field]" => value}` |
| `stream.publish_turbo_stream(action, **options)` or `(html, …)` | `turbo_stream` | `<turbo-stream>` HTML, see [Turbo Streams](#turbo-streams) |
| `stream.publish_visit(url)` | `visit` | URL |
| `stream.publish_finished` | `progress_finished` | none |

`Sossego::PublishingHelpers` is for a job that a page watches. It gives the job its `stream`, read from the `stream_id:` argument (set `sossego_stream_argument` to use another name), and makes sure the page hears how the job ended:

```ruby
class ReceiptOcrJob < ApplicationJob
  include Sossego::PublishingHelpers
  queue_as :interactive                              # give watched jobs a queue of their own
  sossego_retry_on Net::ReadTimeout, attempts: 3     # retry_on, and say so on the stream
  self.sossego_close_stream = true                   # end the stream when the job ends

  def perform(receipt_id:, stream_id:)
    stream.publish_progress("Reading the receipt...")
    stream.publish_field_prefill("expense[amount]" => "12.50")
  end
end
```

A run always ends with `progress_finished`. On a failure, `publish_failure(error)` publishes `error_message` first; the text is `sossego_failure_message(error)`, which you can override to say less. Override `publish_failure` to add to it, for example a `visit` to a page the user can carry on from, calling `super`. A watched job that dies otherwise leaves a spinner turning forever.

The events the concern publishes itself (finished, failure, retrying, close) never raise. A publish that fails is logged and reported to `Rails.error` (`handled: true`, source `"sossego"`, with the job, stream and event in the context), so it can't hide the job's own error, and you still hear about it. The job's own `stream.publish_*` calls raise like any other call. `stream` is nil when the job was given no stream id, so a job that reports only sometimes writes `stream&.publish_progress(...)`.

To give all your watched jobs the same policy (queue, retries, failure message), wrap it in a concern of your own. Include `Sossego::PublishingHelpers` in the module body, not inside `included do`. That makes it a dependency of your concern, so it sits below your concern in the job's ancestors and your overrides win. Included from `included do`, it lands above your concern and silently replaces them:

```ruby
module WatchedJob
  extend ActiveSupport::Concern
  include Sossego::PublishingHelpers   # here, not in `included do`

  included do
    queue_as :interactive
    sossego_retry_on Net::ReadTimeout, Faraday::TimeoutError, attempts: 3
  end

  private

  def sossego_failure_message(error) = "Something went wrong, please try again."
end
```

`Sossego::Enqueuing` guards the moment a controller hands the job off:

```ruby
include Sossego::Enqueuing

if sossego_enqueue(stream, ack: "Queued...") { ReceiptOcrJob.perform_later(receipt_id:, stream_id: stream.id) }
  head :accepted
else
  head :service_unavailable   # the stream was told: error_message + progress_finished
end
```

The failed hand-off is reported to `Rails.error` too, and so is a publish that fails while telling the stream.

## Getting the JavaScript into your app

The client is five small npm packages under `app/javascript/@sossego/` in the gem. They are plain ES modules with `.d.ts` types and need no build step.

| Package | |
|---|---|
| `@sossego/client` | The stream client |
| `@sossego/stimulus` | The Stimulus controller and its handlers |
| `@sossego/highlight` | Highlights fields that were filled for the user; `@sossego/highlight/highlight.css` |
| `@sossego/react` | `useSossegoStream` |
| `@sossego/testing` | `FakeEventSource` and frame builders, for your tests |

The add-ons import `@sossego/client` by name, so every setup must resolve that name.

**importmap-rails** (with Propshaft or Sprockets). Nothing to do: the engine adds the files to the asset path and pins them. `@sossego/react` is pinned but not preloaded; pin `react` yourself to use it. The stylesheet is `stylesheet_link_tag "@sossego/highlight/highlight"`.

**An importmap you write yourself** (assiette, hand-rolled). The engine serves the packages itself at `/sossego/js/<digest>/@sossego/…`. The URLs change when the content does, so they can be cached forever. Merge its entries into your map:

```ruby
map = {imports: {...your pins...}, integrity: {...}}
map.merge!(sossego_importmap) { |_key, yours, ours| yours.merge(ours) }   # also: %w[@sossego/react] if needed
tag.script(map.to_json.html_safe, type: "importmap")
```

```erb
<link rel="stylesheet" href="<%= sossego_asset_path("@sossego/highlight/highlight.css") %>">
```

The entries come with SRI hashes. `@sossego/testing` is never mapped.

**A bundler with node_modules** (esbuild, Vite, webpack). Copy the packages from the installed gem into your app, and link to the copies:

```sh
bin/rails sossego:js:vendor     # copies to vendor/javascript/@sossego/ (DIR= to change) and prints the lines below
```

```json
"dependencies": {
  "@sossego/client": "link:./vendor/javascript/@sossego/client",
  "@sossego/stimulus": "link:./vendor/javascript/@sossego/stimulus"
}
```

Use `file:` instead of `link:` with npm. Commit `vendor/javascript/@sossego`. After each gem upgrade, run the task again. `bin/rails sossego:js:check` fails when the copies, or what's in `node_modules`, differ from the installed gem, so put it in CI. The lockfile records only the relative path: the same on every machine and in Docker. [llm/outputs/js-packaging.md](llm/outputs/js-packaging.md) explains the choice: why not `file:` with yarn, why not a path into the gem's install directory.

## The JavaScript client

```js
import { createSossegoStream, compareCursors, maxCursor } from "@sossego/client"

const stream = createSossegoStream({
  url: "/inbox_stream?account=42",
  lastEventId: renderedCursor,           // resume from what the page rendered; omit to let the server decide
  events: {                              // by event name: (payload, event); names with no handler are ignored
    inbox_changed: () => refresh(),
    email_added: (email, event) => emails.add(email),
  },
  onEvent: (event) => {},                // every event, before its handler in `events`
  onGap: (event, expectedSseq) => refetchEverything(),
  onPing: ({ head, time }) => {},        // head: the stream's newest cursor
  onClose: (reason, seq) => {},          // seq is null when the server refused the stream
  onError: (err) => {},                  // an Event for the connection, an Error for a bad frame or a throwing handler
  onStateChange: ({ status }) => {},     // connecting | open | reconnecting | closed
})
stream.close()
```

- **Order:** each stream decodes its events one at a time and calls their handlers in the order they were published, even when decoding is async (gzip). A handler that returns a promise isn't waited for. See [Async handlers](#async-handlers).
- **Handlers can change:** `events` is read for each event, so adding or replacing a key on the same object takes effect from the next event. Each stream has its own handlers.
- **Cursors** are strings. Compare them only with `compareCursors(a, b)` and `maxCursor(a, b)`, never with `<` or `Number()`.
- **Resilience:** the client reopens a connection that goes quiet for 25 s. When the browser gives up on a connection, the client reopens it with a backoff from 3 s to 60 s. The `close` frame is the only thing that stops it.
- **Formats:** custom payload formats register on both sides: `registerPayloadDecoder(fmt, fn)` here, `Sossego.encoders` / `Sossego.decoders` in Ruby.

## Stimulus

```erb
<div data-controller="sossego"
     data-sossego-url-value="<%= sossego_signed_stream_path(@stream) %>"
     data-sossego-await-task-value="true">
  <div data-sossego-progress hidden><span data-sossego-progress-text></span></div>
</div>
```

| Value | Default | |
|---|---|---|
| `url` | | The stream URL. Opens on connect, closes on disconnect. |
| `last-event-id` | | Cursor for the first connect |
| `await-task` | false | A task is already running: give up if nothing arrives for `task-timeout` |
| `task-timeout` | 180000 | ms. Keep it above the longest silence a healthy task can have, like one slow LLM call. |
| `stalled-message`, `reconnecting-message`, `closed-message` | English | What the progress element says in those cases |

Built-in handlers, by event name:

| Event | What it does |
|---|---|
| `progress` | Shows the text, state `working` |
| `progress_warning` | Shows the text, state `warning`, for 5 s, then fades |
| `error_message` | Shows the text, state `error`, and keeps it up |
| `progress_finished` | State `finished`; the bar lingers 3 s and fades. An error or warning stays. |
| `field_prefill` | Sets the named fields in document order, 300 ms apart, firing `change` and `sossego:prefilled` on each |
| `turbo_stream` | `Turbo.renderStreamMessage(html)` |
| `visit` | `Turbo.visit(url)`, or `location.href` without Turbo |

The progress element is `[data-sossego-progress]` inside the controller's element, or anywhere on the page. Its attribute value is the state (`working`, `warning`, `error`, `finished`), and `data-sossego-fading` is present while it fades. Style it with attribute selectors.

Add your own handlers with `registerHandler("name", (payload, { controller, event }) => …)`, or listen to DOM events. They bubble from the controller's element:

| DOM event | When |
|---|---|
| `sossego:event` | Every event; detail `{eventName, payload, seq, sseq}`. For example `data-action="sossego:event->board#refresh"`. |
| `sossego:complete` | A task settled: finished, warned or failed |
| `sossego:stalled` | An awaited task went silent |
| `sossego:closed` | The stream ended; detail `{reason, seq}` |
| `sossego:disconnected` | The server refused the stream while a task was awaited |

A form that starts its task after the page loaded dispatches `sossego:await-task` on the element to start the timer.

### Highlighting filled fields

```js
import SossegoHighlightController from "@sossego/highlight"
application.register("sossego-highlight", SossegoHighlightController)
```

```erb
<%= stylesheet_link_tag "@sossego/highlight/highlight" %>
<form data-controller="sossego-highlight">…</form>
```

Fields that fire `sossego:prefilled` pulse one after another, and the first is scrolled into view. `field_prefill` fires the event; your own code can too, after filling a field from a suggestion. The `duration` value defaults to 600 ms, and `event` to `sossego:prefilled`. The color comes from `--sossego-highlight-color`.

## Handling your own events

> **Draft. Julik to review.** This is how I meant it to be used. The two notes at the end are open questions.

### How an event reaches your code

1. **Server.** You publish under a name of your own. You choose the payload format when you publish: a Hash goes as JSON, a String as text, and bytes only when you ask (`fmt: :bytes`, or `"gz:bytes"` to gzip them).
2. **Wire.** Every one of your events arrives as one SSE frame named `sossego`. Your name (`"poof"`) is inside the frame, next to the format and the payload.
3. **Decoding.** The client turns the payload back into a value: a JSON value, a string, or a `Uint8Array` for bytes. Gzipped formats are inflated first. Your handler gets the value; there is nothing to decode yourself.
4. **One at a time.** Each stream has a queue that takes one frame at a time: decode it, call its handler, then take the next frame. Handlers are always called in the order the events were published, and a stream never inflates two payloads at once. A page with three streams has three queues.
5. **Routing.** The handler registered for the event's name runs. There are three ways to register one, below.

### Without TypeScript

Server:

```ruby
stream.publish("poof", png_bytes, fmt: :bytes)       # or fmt: "gz:bytes" to gzip it
```

**With the Stimulus controller** (`data-controller="sossego"` already on the page), register a handler once, next to `application.register`:

```js
import { registerHandler } from "@sossego/stimulus"

registerHandler("poof", (bytes, { controller, event }) => {
  const img = controller.element.querySelector("img.poof")
  img.src = URL.createObjectURL(new Blob([bytes], { type: "image/png" }))
})
```

**From a Stimulus controller of your own**, with no registration: every event also bubbles up as `sossego:event`.

```erb
<div data-controller="sossego gallery" data-sossego-url-value="..." data-action="sossego:event->gallery#received">
```

```js
received({ detail: { eventName, payload } }) {
  if (eventName === "poof") this.show(payload)
}
```

This is a DOM event. It is dispatched just before the registered handler for the same event is called.

**Without Stimulus:**

```js
import { createSossegoStream } from "@sossego/client"

createSossegoStream({
  url: "/poof_stream",
  events: { poof: (bytes, event) => show(bytes) },
})
```

`registerHandler` can also replace a built-in handler: `registerHandler("progress", …)` takes over progress messages for every controller on the page.

### With TypeScript

The same code. Annotate the payload with what you published:

```ts
registerHandler("poof", async (bytes: Uint8Array<ArrayBuffer>, { controller }) => { /* ... */ })

createSossegoStream({ url, events: { poof: (bytes: Uint8Array<ArrayBuffer>) => show(bytes) } })
```

Or describe the stream once with an event map. TypeScript then infers each handler's payload, rejects names the map doesn't list, and narrows `onEvent`'s event by `eventName`:

```ts
type ChatEvents = {
  chat_message: { author: string; text: string }
  poof: Uint8Array<ArrayBuffer>
}

createSossegoStream<ChatEvents>({
  url,
  events: {
    chat_message: (message) => append(message.author, message.text),
    poof: (bytes) => show(bytes),
  },
  onEvent: (event) => {
    if (event.eventName === "poof") console.log(event.payload.byteLength)
  },
})
```

`useSossegoStream<ChatEvents>(...)` takes the same map. The map is your word for it: nothing checks that the server publishes `poof` as bytes.

Use `Uint8Array<ArrayBuffer>`, not a bare `Uint8Array`. Since TypeScript 5.7 a bare `Uint8Array` could be backed by a `SharedArrayBuffer`, which `Blob` and some other DOM APIs refuse. Decoded bytes are always backed by an ordinary `ArrayBuffer`.

### Async handlers

Sossego decodes events one at a time and calls their handlers in order. It doesn't wait for a handler that returns a promise: the next event's handler is called as soon as that event is decoded. What a handler does after it returns is up to it.

- **The synchronous part of a handler runs in order.** If you update the DOM before your first `await`, the updates happen in the order the events were published.
- **Work after an `await` runs alongside later events.** If that work must also keep the order, because each event depends on the one before, put it on a queue of your own. `createQueue` is the one Sossego uses itself:

```js
import { createSossegoStream, createQueue } from "@sossego/client"

const inOrder = createQueue(1)           // one at a time; createQueue(4) allows four at once
createSossegoStream({
  url,
  events: {
    row_added: (row) => inOrder.push(async () => {
      const html = await fetch(`/rows/${row.id}`).then((r) => r.text())
      table.insertAdjacentHTML("beforeend", html)
    }),
  },
})
```

- **Errors don't stop the stream.** A handler that throws, or returns a promise that rejects, goes to `onError` (the Stimulus controller logs it).
- **Built-in handlers return at once.** `progress_finished` and `progress_warning` fire `sossego:complete` right away and let the bar linger and fade on its own. A newer message stops the fade, so a task that starts during the linger keeps its bar. `field_prefill` fills fields 300 ms apart. Two prefills that arrive close together can interleave; fields from one event still go in document order.

### Open questions

- **The Stimulus registry is global.** It holds one handler per name for every `sossego` controller on the page; for per-element behaviour, use `sossego:event`. Dispatching a DOM event per name as well (`sossego:poof`) would allow `data-action="sossego:poof->gallery#show"`.

## Using with React

```jsx
import { useSossegoStream } from "@sossego/react"

function Inbox({ stream }) {
  const { status } = useSossegoStream({
    url: stream.url,
    lastEventId: stream.cursor,
    events: { email_added: (email) => addEmail(email) },
    onGap: () => refetch(),
  })
  return <p>{status === "open" ? "Live" : "Connecting..."}</p>
}
```

The hook opens the stream on mount and closes it on unmount. It reopens when `url` or `enabled` change. `events` and the callbacks can change on every render without reconnecting. `enabled: false` pauses the stream without unmounting.

### The pattern: render at a cursor, refetch when behind

Have the server render the page together with the stream's cursor at that moment. Read the cursor before loading the data, so the page never claims to be newer than its rows:

```ruby
stream = Sossego::Stream.for(chat, :messages)
cursor = stream.head.to_s                 # first
messages = chat.messages.order(:id).to_a  # then the data
```

The client resumes from that cursor. Any event means the data on screen is old, so refetch. Debounce the refetch: a burst of events then costs one request. A gap means events were missed; refetch then too.

### Replacing InertiaCable

InertiaCable sends a signal over ActionCable when a model commits, and the client calls `router.reload({ only })`. Sossego does the same over SSE. In addition, a page that was disconnected catches up on what it missed when it comes back.

| InertiaCable | Sossego |
|---|---|
| `broadcasts_to :chat` | `after_commit { Sossego::Stream.for(chat, :messages).publish("changed") }` |
| `inertia_cable_stream(chat)` (a signed token) | `{url: helpers.sossego_signed_stream_path(stream), cursor: stream.head.to_s}`, a signed URL |
| `useInertiaCable(cable_stream, { only, debounce })` | `useSossegoReload(stream, { only, debounce })`, below |
| `broadcast_message_to(chat, data)` (direct messages) | `stream.publish("message_name", data)`, handled in `events` |
| `connected` | `status === "open"` |
| server-side debounce | Not needed: the client debounces, and missed events aren't lost |

The model:

```ruby
class Message < ApplicationRecord
  belongs_to :chat
  after_commit { Sossego::Stream.for(chat, :messages).publish("changed") }
end
```

The controller:

```ruby
def show
  chat = Chat.find(params[:id])
  stream = Sossego::Stream.for(chat, :messages)
  cursor = stream.head.to_s                       # before the messages are loaded
  render inertia: "Chats/Show", props: {
    chat: chat.as_json,
    messages: -> { chat.messages.order(:id).as_json },
    stream: {url: helpers.sossego_signed_stream_path(stream), cursor: cursor}
  }
end
```

The signed URL works like InertiaCable's signed token: whoever has the page can read the stream. To check access on every connect instead, serve the stream from a `Sossego::StreamsController` subclass and put its path in `url`.

The hook, to copy into your app:

```jsx
// app/javascript/hooks/useSossegoReload.js
import { useEffect, useRef } from "react"
import { router } from "@inertiajs/react"
import { useSossegoStream } from "@sossego/react"

// Reloads the given props when the stream says they changed, or that events were missed.
export function useSossegoReload(stream, { only, debounce = 100, onMessage } = {}) {
  const timer = useRef(null)
  useEffect(() => () => clearTimeout(timer.current), [])

  const reload = () => {
    clearTimeout(timer.current)
    timer.current = setTimeout(() => router.reload({ only }), debounce)
  }

  return useSossegoStream({
    url: stream?.url ?? "",
    enabled: Boolean(stream),
    lastEventId: stream?.cursor,
    events: { changed: reload },
    onEvent: (event) => event.eventName !== "changed" && onMessage?.(event),
    onGap: reload,
  })
}
```

```jsx
export default function ChatShow({ chat, messages, stream }) {
  useSossegoReload(stream, { only: ["messages"] })
  return messages.map((m) => <Message key={m.id} message={m} />)
}
```

Direct messages (job progress, a toast) are events with other names. They reach `onMessage` and don't reload anything.

**Several components on one stream.** Each `useSossegoStream` opens its own connection. When the same stream is used in several places, or by a component that remounts on every view switch, share one connection per URL. Cora's shared connection layer does this, keeps hidden tabs from holding connections, and falls back to another transport when SSE is unavailable. It isn't in the gem yet; [llm/outputs/shared-streams.md](llm/outputs/shared-streams.md) describes it.

## Testing your app

**Ruby.** Events are rows: assert on them.

```ruby
Sossego::Event.for_stream("account:#{account.id}:inbox").where(event_name: "inbox_changed").count
Sossego::Event.for_stream(stream.id).order(:id).map { [_1.event_name, _1.value] }  # value decodes the payload
```

Inside transactional tests, `publish_after_commit` publishes at once, and streams on SQLite poll through the test's own connection, so they see the test's rows.

**JavaScript.**

```js
import { installFakeEventSource, FakeEventSource, eventData, pingData, closeData } from "@sossego/testing"

const uninstall = installFakeEventSource()
// …render the code under test…
FakeEventSource.lastInstance().simulateEvent("sossego", "1", eventData("changed", "1", 1, "1", {}))
FakeEventSource.lastInstance().simulateError({ browserGivesUp: true })
uninstall()
```

## Why SSE and not \<something\>Cable

> **Draft. Julik to edit.**

Most "real-time" in a web app goes one way: the server tells the page that something changed. What the page sends back goes as ordinary HTTP requests, with CSRF, cookies, authorization and logs, as everything else does. Server-Sent Events are made for exactly that direction, and that direction alone is what Sossego covers.

What you get from that:

- **It's a normal HTTP response.** No upgrade, no second protocol for the load balancer, proxy, firewall or CDN to support. Authentication is your session cookie, read by a controller like any other. You can watch a stream with `curl -N`, and in the browser's devtools as a list of events.
- **The browser reconnects and resumes on its own.** `EventSource` sends the last event id it saw, and the server continues from there. With ActionCable, whatever was broadcast while a client was disconnected is gone. A page has to reload to be sure it isn't missing something, and it can't even tell whether it missed anything.
- **Events live in your database.** No Redis, no separate cable server, no adapter to keep running. An event can commit, or roll back, with the change it announces. A deploy or a restart loses nothing.
- **Order and gaps are explicit.** Events in a stream come in commit order with a dense sequence number, so a client knows when it has missed something and can refetch.

What it costs:

- **A thread per open stream.** Puma holds one for each open stream, for up to 30 seconds at a time. That's fine for hundreds of open streams per process; for many thousands you'd want a different server model. `max_io_threads` and `max_open_streams` keep streams from crowding out page requests.
- **Polling.** Each stream polls its rows, a quarter second apart by default. That's a cheap indexed query, but it is latency, and load that grows with the number of open streams. An event takes up to `poll_interval_s` to arrive.
- **One direction.** For chatty two-way traffic (collaborative cursors, presence, games), a WebSocket is the right tool.
- **HTTP/1.1 limits a browser to 6 connections per site.** Serve over HTTP/2 when pages keep streams open.

Solid Cable also keeps messages in the database, but it still speaks the WebSocket protocol through ActionCable. It has no cursor and no replay: a client that was away still misses what was sent.
