# Sossego: discrepancies between Moneymaker and Cora, and what the gem does

*18 Oct 2026. Sources: `~/Code/apps/moneymaker` (app/utilities/sossego, SossegoReporting, SossegoEnqueuing, the Stimulus client) and `~/Code/every/cora` (lib/sossego, WIRE_FORMAT.md revision 2, app/javascript/lib/sossego).*

The gem follows Cora's wire format (revision 2, now revision 3 in `WIRE_FORMAT.md`). Cora is the more evolved design, and its spec already listed the changes Moneymaker would need. From Moneymaker the gem takes the parts Cora does not have: SQLite support, signed random streams, the job reporting and enqueue-guard concerns, the progress/prefill/Turbo/visit handlers in a Stimulus controller, the task watchdog, and payload compression.

Each item below says what each app does, what the gem does now, and whether a decision is needed before the gem is published. **Items marked DECIDE need your call.** The rest are settled by Cora's spec, or are mechanical, and are listed so the migration of each app is complete.

---

## A. Storage and publishing

### A1. Table shape
| | Moneymaker | Cora | Gem |
|---|---|---|---|
| Cursor | per-stream `sequence` integer | row `id`, global, sent as a string | Cora |
| Stream sequence | (`sequence`, same column) | `sseq`, dense per stream | Cora |
| Name column | `event_type` | `event_name` | Cora |
| Payload | `message`, **binary**, nullable | `payload`, text, not null | Cora |
| Timestamps | `created_at` + `updated_at` | `created_at` only | Cora |
| Indexes | `(stream_id, sequence)`, **not unique** | `(stream_id, id)`, unique `(stream_id, sseq)`, `created_at` | Cora |

The gem's install generator writes Cora's migration (`create_sossego_events`), then `add_fmt_to_sossego_events`, which adds the `fmt` column (see A3). Cora keeps its table and runs `bin/rails g sossego:install --skip` to get only the second migration. Moneymaker needs a migration; see section G.

### A2. Publish concurrency
- **Moneymaker:** `maximum(:sequence) + 1`, then insert, with no lock and no unique index. It is correct only because SQLite serializes writers. On Postgres two publishers would get the same sequence.
- **Cora:** a per-stream `pg_advisory_xact_lock(hashtext(stream_id))` with `SET LOCAL lock_timeout`. No retry. Postgres only (`pg_sequence_last_value`, `current_setting`).
- **Gem:** chooses by adapter (`Sossego::Event.with_stream_lock`).
  - On Postgres it uses Cora's advisory lock unchanged.
  - On SQLite it opens a plain `transaction(requires_new: true)`. Rails 8 begins with `BEGIN IMMEDIATE`, so the `MAX(sseq)` read already holds the database write lock. The wait is bounded by the connection's busy `timeout:` and ends in `ActiveRecord::StatementTimeout` (I verified this).
  - The head of an empty stream comes from `sqlite_sequence`. Rails creates SQLite primary keys with `AUTOINCREMENT`, so ids are never reused.
  - Any other adapter raises `NotImplementedError`.
  - Both adapters pass the full suite: 163 tests. On Postgres I used a local `sossego_test` database that I created.
- Note: Cora's test "a publish waits for the stream's lock and gives up after lock_timeout_ms" passes vacuously on SQLite. Rails opens transactions lazily, and a lock block that runs no query never issues `BEGIN`. It is now skipped on SQLite, and a separate SQLite test checks that a second writer waits and lands after the first.
- **DECIDE:** should MySQL be supported for 0.1? `GET_LOCK()` would work, but I have not written it.

### A3 + A4 + B1. Payload formats: String payloads, binary payloads, compression

**Decided 18 Oct 2026:** every row stores its `fmt`. The format is fixed at publish and named as on the wire. WIRE_FORMAT is now revision 4.

What each app did before:
- **Cora** stored a String verbatim and, on read, guessed whether it was JSON. `"42"` came back as `42`, and JSON-looking text came back as an object. There was no `fmt` in storage; revision 2 chose the encoding only when the frame was written.
- **Moneymaker** detected text, binary and compression per message, and wrote it as a `data:` prefix (`r:`, `t:`, `b:`, `zt:`, `zb:`).

What the gem does now:
- **Column:** `fmt` (string, not null, default `ejson`). It comes from the new `add_fmt_to_sossego_events` migration.
- **Formats:** `ejson`, `text`, `bytes`, `gz:ejson`, `gz:text`, `gz:bytes`. They are registries on both sides, so a new format is a registry entry, not a wire change.
- **Storage:** `ejson` is stored as JSON text and `text` as the text itself. `bytes` and every `gz:` format are stored as base64 in the same `text` column.
- **Choosing the format at publish:** a String becomes `text`, anything else becomes `ejson`. Bytes are never guessed from a String's encoding; you pass `fmt: :bytes`. Nothing is inferred from a String's content.
- **Compression:** gzip can be fixed at publish (`fmt: "gz:text"`), or applied as the frame is written with `compress_above_bytes:` on the endpoint. A row already stored with a `gz:` format goes out as stored.
- **Older rows:** rows from before the column read as `ejson`. An `ejson` row whose payload does not parse (one of Cora's verbatim strings) goes out as `text`.
- **Clients:** JSON values still go out as `ejson`, so Cora's current client keeps working for everything Cora publishes today. The gem's JS client decodes all six formats; `bytes` arrive as a `Uint8Array`.
- **Reading a value in Ruby:** `Sossego::Event#value`.

Moneymaker's binary support (A4) and its compression (B1) are back under this scheme.

### A5. Retention
- **Moneymaker:** 12 h (`Sossego.delete_events_older_than`). `CleanupJob` runs every 30 minutes, with `supersedes_pending_runs`, `stale_after 1.hour` and priority 60. Those three are Moneymaker's own ApplicationJob extensions.
- **Cora:** 24 h. `PruneJob` runs daily, `queue_as :low`, in batches of 10k.
- **Gem:** `Sossego.retention` defaults to 24 h. `Sossego::PruneJob#perform(older_than: Sossego.retention)` deletes in batches. The job inherits `ActiveJob::Base`, so hosts set the queue and schedule. The job name follows Cora (`PruneJob`), so Moneymaker's `config/recurring.yml` entry must change.
- **Decided 18 Oct 2026:** the default stays 24 h. The install generator now writes `config/initializers/sossego.rb`, which sets `Sossego.retention = 24.hours` explicitly, so the choice is visible, and lists the other settings, commented out. Moneymaker sets 12 h there if it wants to keep today's behaviour. An app upgrading with `--skip` keeps its own initializer.

### A6. Reserved event names
- **Moneymaker** has none; its app event names go straight into the SSE `event:` field.
- **Cora/gem:** `sossego ping close open error message` are reserved. `Sossego::ReservedEventName` is raised at publish.
- Moneymaker's names (`progress`, `progress_warning`, `error_message`, `field_prefill`, `progress_finished`, `visit`, `turbo`) are all allowed.
- While building the chat demo I published `message` and got the error, so the guard works. Under revision 2 app names never reach the SSE `event:` field, so the reservation is now only a safety rule. Keep it, which is my recommendation, or drop it.

---

## B. Server streaming

### B1. Wire format
- **Moneymaker:** the SSE `event:` is the app event name. `id:` is the per-stream sequence. `data:` is a prefixed string. There is no `retry:`, no ping and no envelope.
- **Cora/gem:** three SSE names (`sossego`, `ping`, `close`). The JSON envelope has `fmt`/`evt`/`seq`/`sseq`/`head`/`sid`/`pld`. There is a `retry:` directive and a heartbeat ping.
- **Gem:** Cora's format. Payload formats and compression are decided; see A3 + A4 + B1 above.

### B2. Polling
- **Moneymaker:** sleeps 0.2 s, fetches **one** event per poll, and runs one query per event.
- **Cora:** 0.25 s default (the inbox uses 1 s), batches of 100, the head derived from the batch, and no connection leased while asleep.
- **Gem:** Cora's.

### B3. Resume cursor and replay
- **Moneymaker:** without a `Last-Event-ID` it starts from 0, a full replay. This is required: redirect flows (`invoices#kick_off_prefill`, `bank_accounts#auto_classify`) publish before the page connects.
- **Cora:** the base body also replays everything without a cursor. The inbox subclass sets `max_backlog: 100`, which starts a cursorless connection at the head.
- **Gem:**
  - Without options the body replays everything.
  - The engine's `Sossego::SignedStreamsController` uses no options, so Moneymaker's redirect flows work. The dummy app's "Prepare a report" demo exercises exactly this.
  - `?last_event_id=` is accepted as a fallback to the header, as in Cora. Moneymaker had only the header.
- Not a conflict, just two configurations.

### B4. Cursor validation
- **Moneymaker:** `request.headers["Last-Event-ID"].to_i`, so garbage becomes 0 and the stream replays.
- **Cora:** `\A\d+\z`, and anything else counts as no cursor.
- **Gem:** `\A\d{1,19}\z`. A 20+ digit cursor would pass Cora's check and then make Postgres fail the bigint cast inside the streaming body. `Sossego::Event.cursor_valid?` is still the override point for UUID hosts.

### B5. Controller base class and authorization
- **Moneymaker:** `Sossego::StreamsController < ApplicationController`. It is one concrete controller, and a bad signature gets a **403 head**.
- **Cora:** an abstract base `< ActionController::Base`. Subclasses provide `sossego_stream`. Refusals are **HTTP 200 plus a `close` frame**, because an EventSource cannot read a 403 and would keep reconnecting.
- **Gem:** Cora's base, plus `Sossego::SignedStreamsController`, the Moneymaker use case. A bad or missing signature is now an in-band `forbidden` refusal, not a 403.
  - The Moneymaker client reacted to the 403 via `readyState === CLOSED` → "Lost the connection…".
  - With the gem, the Stimulus controller shows `closedMessage` when a refusal arrives during an awaited task.

### B6. Session writes on the stream response
- **Cora** worked out that a stream response must never write the session cookie: on every reconnect it would overwrite a newer session (sign-out, account switch). Cora's *subclass* sets `request.session_options[:skip] = true`, and the solutions doc tells other subclasses to copy it.
- **Moneymaker** inherits `ApplicationController` with no skip, so it has this bug latently.
- **Gem:** the base controller skips the session write on every served or refused response. `skip_session_write?` can be overridden.

### B7. Stream budget, ping-first, backlog, retry jitter, gauges
- Cora-only features: `max_open_streams` with an `over_budget` refusal, `open_streams_gauge`, `on_over_budget`, `ping_first`, `max_backlog`, and a `retry_ms` range.
- The gem has all of them. Moneymaker sets Puma's `max_io_threads 32` with no cap on streams; that is app config, which the gem documents but does not set.

### B8. Readonly connection for polling (SQLite)
- **Moneymaker:** the body polls through `ReadonlyEvent`, a model with its own connection pool opened with `readonly: true` (SQLITE_OPEN_READONLY), created lazily under a mutex. It is skipped in tests because of transactional fixtures.
- **Cora:** none. It relies on queries not leasing a connection while asleep.
- **Decided 18 Oct 2026:**
  - **Default:** each poll uses whatever connection the app gives `Sossego::Event`.
  - **`Sossego.around_poll`:** a callable that wraps every poll, so the app decides which connection the poll runs on.
  - **`Sossego.poll_on_readonly_sqlite_connection!`:** packages Moneymaker's approach as one line. On the first poll it registers a copy of the SQLite connection with `readonly: true` under a role of its own. That opens the file with SQLITE_OPEN_READONLY, and nothing needs declaring in `database.yml`.
  - **`Sossego.connection_class`:** names the class to call `connected_to` on (`ActiveRecord::Base`, or `Sossego::ApplicationRecord` when `connects_to` is set).
  - **Initializer:** the generated initializer has recipes for a reading role, the read-only SQLite copy (`unless Rails.env.test?`, as Moneymaker did) and a custom wrapper such as a shard.
  - **Tests:** the read-only copy sees committed events, cannot write, and is the connection the poll actually uses. The reading-role recipe is tested as written in the initializer. The dummy app uses the read-only copy in development, and I checked a live stream through it.
  - **Removed:** the earlier `Sossego.reading_role` setting.
  - **Still available:** `Sossego.connects_to`, for a database of its own.

---

## C. Stream identity

### C1. Ids
- **Moneymaker:** bare random ids, `SecureRandom.base36(8)`, e.g. `k7p2qd9z`.
- **Cora:** record-derived, `account:42:inbox` via `Stream.for(record, channel)`.
- **Gem:** both. `Stream.for` as in Cora, and `Stream.random(channel = :progress, namespace: :task)`, which gives `task:<12 base36>:progress` and matches the example in Cora's spec.

### C2. Signing
- **Moneymaker:**
  - `Rails.application.message_verifier(:sse_streams)`, purpose `:sse_stream`;
  - URL `/sossego/:stream_id?sig=…`;
  - `Event.verified_stream_id_from_url`.
- **Gem:**
  - `Sossego.verifier`, which defaults to `message_verifier("sossego_streams")`, purpose `:sossego_stream`;
  - URL `/sossego/streams/:stream_id?sig=…` from the mounted engine;
  - `Stream#signature(expires_in:)`, `Stream.verified(id, sig)`, `Stream.verified_from_url(url)`;
  - the helpers `sossego_signed_stream_path/url(stream)`;
  - comparison with `secure_compare`.
- Signed URLs already issued by Moneymaker will not verify after the switch. They live for one task, so this only matters during a deploy.
- **Decided 18 Oct 2026:** the URL keeps the readable id: `/sossego/streams/<stream id>?sig=<message verifier signature>`. Stream ids stay readable in logs and the network tab, and the Rails verifier gives expiry (`signature(expires_in:)`) and secret rotation. The longer URL doesn't matter: it is never typed or shared.
- Cora's plan rejected signed tokens for the inbox (it checks membership on each connect). That is a per-endpoint choice, and both remain possible.

---

## D. Jobs and controllers (Moneymaker only)

### D1. `SossegoReporting` → `Sossego::Reporting`
**Kept:**
- every run ends with a terminal event (`progress_finished` on success; `error_message` + `progress_finished` on any `StandardError` or `ScriptError`);
- the stream is read back off the job's keyword arguments;
- a failed publish never raises;
- the `publish_*` helpers.

**Changed:**
- `queue_as :interactive` is no longer forced. Choosing a queue is the host's call, and the docs say to give these jobs a dedicated queue.
- `TRANSIENT_ERRORS` named RubyLLM, Faraday and Net errors. That list is now declared per job: `sossego_retry_on(*errors, attempts:, wait:)`.
- The failure message for exhausted transient errors used to be "Could not reach the AI service…". It is now the generic `sossego_failure_message(error)`, which can be overridden.
- `publish_turbo_stream` publishes `turbo_stream`; it was `turbo` (see E2).
- `publish_field_prefill` takes a Hash. It used to take a JSON string.
- The stream argument is configurable: `self.sossego_stream_argument = :stream_id`.

**Decided 18 Oct 2026:** a job closes its stream only if it opts in.
- `self.sossego_close_stream = true` publishes a stored `close` after `progress_finished`. The reason is `finished` on success and `failed` when attempts run out; the stream stays open between retries.
- The default is off, so a stream that a form reuses for several tasks is never closed under it.
- The README ("Streams that end") and WIRE_FORMAT §6.4 describe when to close: one-off tasks with progress, wizard steps, anything with a natural end.
- The Stimulus controller treats a published close during an awaited task as the task ending (`sossego:complete`, no error). Only a refusal, which has no `seq`, shows the "lost the connection" message.
- The dummy app's `DemoPreparationJob` opts in.

Moneymaker's redirect flows (`InvoicePrefillJob`, `TransactionClassifyJob`) should opt in. Its form-page jobs (`ReceiptOcrJob`, `AssetRecognitionJob`) should not.

### D2. `SossegoEnqueuing` → `Sossego::Enqueuing#sossego_enqueue(stream, ack:)`
- The same behaviour: ack `progress`, yield, and on failure `error_message` + `progress_finished` + `false`.
- The failure text is generic ("Could not start the task…"); it was "…the analysis…".
- Cora's spec suggests `after: 0` on the ack. That is not used, for the same reason as D1.

### D3. App-specific pieces left in Moneymaker
- `RubyLLM::Chat#with_sossego_progress` (config/initializers/ruby_llm_callbacks.rb).
- `InvoicePrefillJob#publish_failure`, which adds a `visit`. It still works as an override.
- The 503 / 422 responses in its controllers.

### D4. Cora's `ClientPush::InboxSignal` publish pattern
- It publishes after all transactions commit (`ActiveRecord.after_all_transactions_commit`).
- It drops, reports and counts a failed publish.
- It is gated by a flag.
- **Decided 18 Oct 2026:** the gem has `Stream#publish_after_commit(name, payload, fmt:, on_error:)`.
  - It publishes once every open transaction has committed, through `ActiveRecord.after_all_transactions_commit`, and publishes nothing on a rollback.
  - The name and `fmt` are checked at the call.
  - With `on_error`, a failed publish goes to the callback and does not raise. Without it, the error raises after the commit.
  - No `after:`: a conditional append checked after the commit would check against a stream that has moved on.
  - Inside a host's transactional tests it publishes at once, which is pinned by a test.
  - Cora's `ClientPush::InboxSignal#run` shrinks to its flag check plus `Sossego::Stream.for(account, :inbox).publish_after_commit(event_name, payload, on_error: ->(e) { count_and_report(e) })`.

---

## E. JavaScript client

### E1. Packaging (as asked: no TS compiler needed)
- **Cora:** TypeScript across seven modules, with generics (`SossegoEvent<T>`, `on<T>`).
- **Moneymaker:** plain JS, one Stimulus controller and eight handler modules.
- **Gem:** plain ES modules with JSDoc, and a hand-written, deliberately loose `app/javascript/sossego.d.ts` for TypeScript users.
  - `app/javascript/sossego.js` is the core (stream, cursors, decode, queue, dispatcher, in one file).
  - `app/javascript/sossego/stimulus.js` is the controller and handlers.
  - `app/javascript/sossego/react.js` is `useSossegoStream`.
  - Why one core file: Propshaft serves only digested asset URLs, so relative `./x.js` imports between modules 404 under importmap. The two add-ons import the core by its bare name `sossego`, which resolves both through the engine's importmap pins and as an npm package (`package.json` `exports`).
  - Cora's TS tests were converted mechanically with Node's type stripper, and all 65 pass unchanged in behaviour. There are 81 JS tests in total (`npx vitest run`).

### E2. Event names and DOM contract (Moneymaker → gem)
| Moneymaker | Gem |
|---|---|
| controller `sossego-client`, `data-sossego-client-stream-url-value` | the host registers `sossego/stimulus` under any name (`sossego` in the docs), `data-sossego-url-value` |
| `data-sossego-client-await-task-value`, `sossego:await-task` | `data-sossego-await-task-value`, `sossego:await-task` (unchanged) |
| `[data-sse-progress]`, `[data-sse-progress-text]` | `[data-sossego-progress]` (its value is the state: `working`/`warning`/`error`/`finished`), `[data-sossego-progress-text]` |
| CSS classes `ocr-progress-bar--error/--warning/--fading`, `ocr-progress-indicator--stopped`, emoji icon elements injected by JS | state attribute and `data-sossego-fading`; icons come from CSS (see the dummy app's `demo.css`) |
| `turbo` event, `Turbo.renderStreamMessage` | `turbo_stream` event |
| `moneymaker:magic` on prefilled inputs, animated by the app's `magic-fields` controller | `sossego:prefilled`, animated by the gem's `sossego/highlight` controller and `sossego/highlight.css` (see E7) |
| `sossego:complete`, `sossego:stalled`, `sossego:disconnected`, `sossego:event` | same names; `sossego:event` detail now carries `{eventName, payload, seq, sseq}`; new `sossego:closed` |
| `event.decodedTextData` / `decodedBinaryData` given to handlers | handlers get `(payload, {controller, event})` with the decoded `pld` |
| handlers fixed by import | `registerHandler(name, fn)`, or listen to `sossego:event` |
| global `document.querySelector` for the progress bar | the progress element inside the controller element first, then the document |

**Decided 18 Oct 2026:** all the renames above are accepted: `turbo_stream`, the `data-sossego-*` attributes, and the state as an attribute value. Field highlighting ships as `sossego/highlight` (E7). Moneymaker's side of this is in `~/Code/apps/moneymaker/llm/todos/sossego-migration.md`.

### E7. Field highlighting (Moneymaker's "magic fields")
- **Moneymaker:** `magic_fields_controller.js` listens for `moneymaker:magic`. It plays a 600 ms pulse on each field, one at a time, the next starting halfway through, and scrolls the first field into view. Fields are filled by `field_prefill` and also by a plain `fetch` (the VAT suggestion in `expense_form_controller.js`).
- **Gem:** ships it as a companion controller, `sossego/highlight`, rather than inside the `field_prefill` handler, so non-stream fills use it too.
  - It listens for `sossego:prefilled` by default; the event name is configurable.
  - It marks the field with `data-sossego-highlighted`.
  - `app/assets/stylesheets/sossego/highlight.css` has the same pulse, plus a reduced-motion fallback.
  - The prefill handler's 300 ms stagger matches the highlight's half-duration, as before.
  - I checked the sequence in the demo in a browser.
- **Fixed on the way:** Moneymaker's `disconnect` calls `removeEventListener(..., this.enqueue.bind(this))`. `bind` returns a new function, so nothing is removed, and after a Turbo reconnect every field glows twice.

### E3. Connection-level behaviour
- **Moneymaker:** native EventSource reconnect only. "Trying to reach the server…" appears after 3 errors in a row; `readyState CLOSED` means "Lost the connection, reload". The 180 s task watchdog closes the stream.
- **Cora:** a 25 s stall timer (needs the server pings). On `CLOSED` it reopens with a jittered backoff from 3 s to 60 s. It reopens with `?last_event_id=`. A frame and an error are handled in wire order. `close` frames are final.
- **Gem:** Cora's core underneath, Moneymaker's watchdog (`taskTimeout`, default 180 s) and the 3-errors message on top. Because the core never gives up on a failed connection, Moneymaker's "Lost the connection" now appears only when a `close` frame ends a stream during an awaited task.
- **Cora's `withCredentials: true` was hard-coded**. In the gem it is an option, still defaulting to true.

### E4. Gap detection
- **Cora:** done in the app (`inboxStreamConnection.ts`), from `sseq`.
- **Gem:** in the core, as `onGap(event, expectedSseq)`, called before the event. The first event is never a gap. This is per WIRE_FORMAT §8.

### E5. Dispatcher
- **Cora:** a module-global registry, `on`/`dispatch`/`_resetForTesting`; the handler gets the payload.
- **Gem:** `createDispatcher()` returns `{on, off, dispatch}`. Handlers get `(payload, event)`. There is no global registry, so two streams on a page do not share handlers.
- Cora would need a two-line change if it adopted the gem's client.

### E6. Not ported from Cora's app layer (`inboxStreamConnection.ts`)
These are generic enough for the library but not yet in it:
- the per-URL shared connection with refcount and linger;
- closing after 30 s hidden and resuming on visibility;
- `knownHead` tracking;
- the silent-first-frame / three-strikes / fallback-cooldown state machine;
- `catchUpOwed`.

**Decided 18 Oct 2026:** leave it in Cora for now, and port it when Cora moves to the gem's client, with Cora as the second real user. The architecture, the server contract, a proposed `createSharedStreams` API and the next iterations are in [shared-streams.md](shared-streams.md). Cora's checklist is `~/Code/every/cora/docs/plans/2026-10-18-chore-sossego-gem-migration-plan.md`, section 6. The gem now ships the test helpers both will need, as `sossego/testing` with types.

---

## F. Packaging questions

- **License:** ~~DECIDE~~ **Decided 18 Oct 2026: MIT.** `LICENSE.md`, gemspec and `package.json` updated.
- **Names:** `sossego` is free on both RubyGems and npm today. The npm package's add-ons import `"sossego"` by name, so a scoped npm name (`@julik/sossego`) would need those imports changed.
- **Homepage/repo:** the gemspec points at `github.com/julik/sossego`, which Cora's comments mention. Confirm it exists or should be created.
- **Rails floor:** `>= 8.0`, because the SQLite lock relies on Rails 8's `BEGIN IMMEDIATE` default. Ruby `>= 3.4`.
- **Turbo Stream helpers:** Moneymaker's packaging todo wanted `Sossego::TurboStream.replace(stream, target:, partial:)`. The gem has only `publish("turbo_stream", html)`, shown in the board demo, and `Reporting#publish_turbo_stream`. **DECIDE:** add the helpers?
- **Subscriber fan-out:** Moneymaker's ActionCable-replacement analysis proposed "address subscribers, not topics" (`Sossego.notify(subscriber, …)`). Not started. It is a later version, if ever.

---

## G. Migrating each app onto the gem

### Moneymaker
1. Events are ephemeral (12 h), so drop the old table rather than convert it. Then run `bin/rails g sossego:install` for the gem's two migrations. The drop must run first: the gem's create migration expects no table.
   ```ruby
   class DropLegacySossegoEvents < ActiveRecord::Migration[8.1]
     def up
       drop_table :sossego_events
     end
   end
   ```
2. Delete `app/utilities/sossego*`, `SossegoReporting`, `SossegoEnqueuing`, `Sossego::CleanupJob`, the Stimulus controller and `sossego_handlers/`.
3. Routes: replace `get "sossego/:stream_id"` with `mount Sossego::Engine => "/sossego"`.
4. Controllers:
   - `Sossego::Event.generate_stream_id_with_signature` → `stream = Sossego::Stream.random`, with `sossego_signed_stream_path(stream)` in views;
   - `verified_stream_id_from_url` → `Sossego::Stream.verified_from_url`;
   - `enqueue_reporting_to(stream_id, ack:)` → `sossego_enqueue(stream, ack:)`.
5. Jobs: `include Sossego::Reporting`, keep `queue_as :interactive`, and declare `sossego_retry_on(*TRANSIENT_ERRORS, attempts: 3)`. Pass the Hash to `publish_field_prefill`, not JSON. Progress text, URLs and Turbo HTML go out as `text` with no change. Rename `publish_turbo_stream`'s event if (E2) goes that way.
6. Views and CSS: the attribute renames in E2. In `file_upload_controller.js`, read the URL from `dataset.sossegoUrlValue`.
7. `recurring.yml`: replace `Sossego::CleanupJob` with `Sossego::PruneJob`, and set `Sossego.retention = 12.hours` if wanted.

### Cora
1. The table is already the gem's shape. Keep it.
2. Delete `lib/sossego*` and `app/jobs/sossego/prune_job.rb`. `ClientPush::EventsController` keeps working as a subclass. Its `request.session_options[:skip]` line is now redundant, and harmless.
3. If it adopts the gem's client: imports change from `@/lib/sossego/*` to `sossego` (or the copied path), and `on`/`dispatch` change to `createDispatcher()`. Gap detection could move from `inboxStreamConnection.ts` to `onGap`.
4. `Sossego::PruneJob` no longer sets `queue_as :low`. Set it in an initializer if the queue matters.
5. Payload formats (A3): run `bin/rails g sossego:install --skip` for the `fmt` column. No Cora caller publishes a String today. Verbatim strings stored by Cora's old code still go out as `text`.
