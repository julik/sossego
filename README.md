# Sossego

*"Sossego, eu preciso de sossego" - Tim Maia, 1977*

Server-Sent Events for Rails, backed by a database table.

Events are rows in an append-only `sossego_events` table. A plain Rack body polls the table for one stream and writes SSE frames. The browser resumes by cursor through `Last-Event-ID`. There is no `ActionController::Live`, no Redis and no pub/sub server, and a server restart loses nothing.

It runs on SQLite and PostgreSQL. The JavaScript client is plain ES modules, so no build step is needed. It comes with a Stimulus controller and a React hook.

The wire format is specified in [WIRE_FORMAT.md](WIRE_FORMAT.md).

## Installation

```ruby
gem "sossego"
```

```sh
bin/rails generate sossego:install   # migrations, config/initializers/sossego.rb, mounts the engine at /sossego
bin/rails db:migrate
```

After upgrading the gem, run `bin/rails generate sossego:install --skip` to add any migrations you don't have yet.

Schedule the cleanup, for example with Solid Queue:

```yaml
# config/recurring.yml
sossego_prune:
  class: Sossego::PruneJob
  schedule: every hour
```

Events older than `Sossego.retention` are deleted. The installer sets this to 24 hours in `config/initializers/sossego.rb`. The other settings are listed there too, commented out: a database of its own, the signing verifier, and the Postgres lock timeout. So are recipes for choosing the connection streams poll on (`Sossego.around_poll`). A stream polls on your app's connection by default. The recipes cover a reading role and, for SQLite, `Sossego.poll_on_readonly_sqlite_connection!`, which polls through a read-only copy of the database file.

## Publishing

```ruby
stream = Sossego::Stream.for(account, :inbox)   # "account:42:inbox"
stream.publish("inbox_changed", {count: 3})
stream.publish("progress", "Halfway there")    # a String goes out as text, as it is
stream.publish("thumbnail", png, fmt: :bytes)  # bytes are always asked for
stream.publish("turbo_stream", html, fmt: "gz:text")  # stored and sent gzipped
stream.publish_close(reason: "finished")        # ends the stream for every client, for good
```

Each row stores its `fmt` (`ejson`, `text`, `bytes`, or a gzipped `gz:` variant of those), and the client hands over the value it describes: the parsed JSON value, the string, or a `Uint8Array`. Set `compress_above_bytes:` on an endpoint to gzip large payloads as they go out.

Within a stream, events arrive in the order they were committed. Each event has a cursor (`seq`, the row id) and a dense per-stream sequence (`sseq`), which clients use to detect gaps. With `after:`, a publish appends only if the stream is where you think it is:

```ruby
stream.publish("progress", "Queued", after: 0)  # Sossego::Conflict unless the stream is empty
```

### Publishing from inside a transaction

`publish` writes inside the caller's transaction. A reader can see the event as soon as it commits, but if the transaction rolls back, the event goes with it. To announce a change only once it is visible, use `publish_after_commit`. It waits until every open transaction has committed, and publishes nothing on a rollback:

```ruby
Order.transaction do
  order.update!(state: "paid")
  stream.publish_after_commit("order_paid", {id: order.id},
    on_error: ->(error) { Rails.error.report(error, handled: true) })
end
```

With `on_error`, a publish that fails is handed to the callback and doesn't raise. That suits signals you can afford to lose, like "the inbox changed, refetch". Without `on_error`, the error raises after the commit, and the committed change stands.

## Serving a stream

Subclass `Sossego::StreamsController` and name the stream:

```ruby
class InboxStreamsController < Sossego::StreamsController
  def show
    return refuse_stream("unauthenticated") unless current_user
    @account = current_user.accounts.find_by(id: params[:account])

    super  # refuses with "forbidden" when sossego_stream returns nil
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

An EventSource cannot read an error status. So a refusal is HTTP 200 with a single `close` frame naming the reason, and the client stops instead of reconnecting forever. The stream response never writes the session cookie.

Every open stream holds a Puma thread for up to 30 seconds before the client reconnects. Set Puma's `max_io_threads`: streams mark themselves IO-bound, so they don't take regular request threads. Use the same number for `max_open_streams`.

### Streams for one task

A stream made for a single background job can be handed to the browser signed. The engine serves it:

```ruby
@stream = Sossego::Stream.random   # "task:k7p2qd9z4m1x:progress"
```

```erb
<div data-controller="sossego" data-sossego-url-value="<%= sossego_signed_stream_path(@stream) %>"></div>
```

## Background jobs with progress

```ruby
class ReceiptOcrJob < ApplicationJob
  include Sossego::Reporting
  queue_as :interactive                       # keep it out from behind slow work
  sossego_retry_on Net::ReadTimeout, attempts: 3

  def perform(receipt_id:, stream_id:)
    publish_progress("Reading the receipt...")
    publish_field_prefill("expense[amount]" => "12.50", "expense[currency]" => "EUR")
  end
end
```

Each run ends with `progress_finished`, however it exits. A failure publishes `error_message` first. The spinner never hangs.

### Streams that end

A stored `close` ends a stream for good: every client reading it stops, and none reconnects. A job ends its stream that way with one setting:

```ruby
class InvoicePrefillJob < ApplicationJob
  include Sossego::Reporting
  self.sossego_close_stream = true   # after progress_finished: close, reason "finished" or "failed"
end
```

Close the stream when it belongs to that one piece of work:

- **One-off tasks with progress.** The page starts a task, gets a `Stream.random` for it, and waits ("Preparing your report..."). When the task is done there is nothing more to hear, and the stream should stop costing a server thread.
- **Wizards.** Each step runs a job on its own stream and moves on (`publish_visit`) when the job finishes. The next step makes a new stream.
- **Anything with a natural end**, such as a generation that streams tokens and then completes, or an import that runs once.

Leave it open when a page keeps one stream for several tasks. For example, a form that opens its stream on render and can analyze a second upload after the first: a closed stream hears nothing after the close. Jobs don't close streams unless told to.

Outside jobs, `stream.publish_close(reason: "...")` does the same thing. In the browser, the client calls `onClose(reason, seq)`, and the Stimulus controller fires `sossego:closed`. A refusal from the server is also a close, but with `seq` null.

Controllers that start such jobs can guard the hand-off:

```ruby
include Sossego::Enqueuing

stream = Sossego::Stream.verified_from_url(params[:stream_url]) or return head(:forbidden)
sossego_enqueue(stream, ack: "Queued...") { ReceiptOcrJob.perform_later(receipt_id: 1, stream_id: stream.id) }
```

Other helpers: `publish_warning`, `publish_error`, `publish_visit(url)`, `publish_turbo_stream(html)` and `publish_failure(error)`.

## JavaScript

With importmap-rails, the engine pins `sossego`, `sossego/stimulus` and `sossego/react`. With a bundler, install the same files from npm as `sossego`.

### Plain JS

```js
import { createSossegoStream, createDispatcher } from "sossego"

const events = createDispatcher()
events.on("inbox_changed", (payload, event) => refresh())

const stream = createSossegoStream({
  url: "/inbox_stream?account=42",
  lastEventId: renderedHead,                 // resume from what the page rendered
  onEvent: events.dispatch,
  onGap: (event, expectedSseq) => refetchEverything(),
  onClose: (reason) => fallBackToPolling(reason),
})
```

Events reach your handlers in wire order, even when a handler is async. The client reopens stalled or failed connections with backoff.

### Stimulus

```js
import SossegoController from "sossego/stimulus"
application.register("sossego", SossegoController)
```

```erb
<div data-controller="sossego"
     data-sossego-url-value="<%= sossego_signed_stream_path(@stream) %>"
     data-sossego-await-task-value="true">
  <div data-sossego-progress hidden><span data-sossego-progress-text></span></div>
</div>
```

The controller has built-in handlers for the events `Sossego::Reporting` publishes:

| Event | What it does |
|---|---|
| `progress` | Shows the message. |
| `progress_warning` | Shows the warning for a while, then hides it. |
| `error_message` | Shows the error and keeps it visible. |
| `progress_finished` | Ends the task. |
| `field_prefill` | Fills the named fields one by one. |
| `turbo_stream` | Renders the Turbo Stream HTML. |
| `visit` | Navigates to the URL. |

You can add your own handlers with `registerHandler(name, fn)`, or react to the bubbling `sossego:event` DOM event. The progress element's state (`working`, `warning`, `error` or `finished`) is the value of its `data-sossego-progress` attribute, so you can style it with attribute selectors.

### Highlighting filled fields

`field_prefill` fires `sossego:prefilled` on each field it changes. The `sossego/highlight` controller makes those fields pulse, one after another, and scrolls the first into view:

```js
import SossegoHighlightController from "sossego/highlight"
application.register("sossego-highlight", SossegoHighlightController)
```

```erb
<%= stylesheet_link_tag "sossego/highlight" %>
<form data-controller="sossego-highlight">...</form>
```

To highlight a field your own code filled, dispatch `sossego:prefilled` on it.

### React

```js
import { useSossegoStream } from "sossego/react"
const { status } = useSossegoStream({ url, onEvent: (e) => console.log(e.eventName, e.payload) })
```

## Demos

The dummy app is also a set of demos:

- a job filling in a form, with progress;
- a job that redirects when it is done;
- a chat using only the plain JS client;
- a Turbo Streams board.

```sh
bundle install
cd test/dummy && bin/rails db:prepare && bin/rails server
```

## Development

```sh
bundle exec rake          # minitest (SQLite) + standardrb
DATABASE_URL=postgres://localhost/sossego_test bundle exec rake test
npm install && npx vitest run
```

## License

MIT, see [LICENSE.md](LICENSE.md).
