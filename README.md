# Sossego

*"Sossego, eu preciso de sossego" - Tim Maia, 1977*

Server-Sent Events for Rails, from a database table. You publish an event and it becomes a row. Each open stream polls for new rows and sends them to the browser, which resumes where it left off after a reconnect. No Redis, no WebSocket server, no `ActionController::Live`. Works on SQLite and PostgreSQL.

Replaces ActionCable, because SSEs are just a better fit for most apps.

## Why Sossego

You should not need socket upgrades, separate authentication and a persisted channel - using an HTTP connection is just simpler. But that's not all. Here is all the stuff you get for free with SSE+Sossego:

* No separate socket handling and no "suckerpunch" server threads
* Unlimited number of streams you can open - limited only by the number of connections your server can support
* Automatic replay from offset (the browser does this, by itself, with zero extra code)
* Visible and debuggable events in your dev console
* A clear, _push only_ development model
* They multiplex onto the HTTP/2 connection your browser already has
* On servers like Falcon it will handle a ridiculous number of connections
* It just polls. No socket leakages, no connection exhaustion.
* Works through proxies
* Uses the same auth you already have (plus signed URLs)


If you need more convincing (though [I don't have to convince you of anything](https://blog.julik.nl/2024/02/change-my-mind)), you can always read these articles that put it way better than I ever could:

* [WebSockets, caution required!](https://samsaffron.com/archive/2015/12/29/websockets-caution-required) by Sam Saffron
* [Server-Sent Events: the alternative to WebSockets you should be using](https://germano.dev/sse-websockets/)
* [Server-sent events are cool](https://jvns.ca/blog/2021/01/12/day-36--server-sent-events-are-cool--and-a-fun-bug/)

## Install

```ruby
gem "sossego"
```

```sh
bin/rails generate sossego:install   # migrations, config/initializers/sossego.rb, mounts the engine at /sossego
bin/rails db:migrate
```

Delete old events on a schedule:

```yaml
# config/recurring.yml
sossego_prune:
  class: Sossego::PruneJob
  schedule: every hour
```

With importmap-rails the JavaScript is already pinned: `@sossego/client`, `@sossego/stimulus`, `@sossego/highlight`. Register the Stimulus controller:

```js
// app/javascript/controllers/index.js
import SossegoController from "@sossego/stimulus"
application.register("sossego", SossegoController)
```

Not on importmap-rails? See [Getting the JavaScript into your app](MANUAL.md#getting-the-javascript-into-your-app).

## Live updates with Turbo Streams

Serve a stream. Here, one per account:

```ruby
# config/routes.rb
get "live" => "live_streams#show"

# app/controllers/live_streams_controller.rb
class LiveStreamsController < Sossego::StreamsController
  def show
    return refuse_stream("unauthenticated") unless current_user
    super
  end

  protected

  def sossego_stream = Sossego::Stream.for(current_user.account, :live)
end
```

Listen on the page:

```erb
<div data-controller="sossego" data-sossego-url-value="<%= live_path %>"></div>
```

Publish Turbo Streams to it:

```ruby
class Comment < ApplicationRecord
  after_create_commit do
    Sossego::Stream.for(account, :live)
      .publish_turbo_stream(:append, target: "comments", partial: "comments/comment", locals: {comment: self})
  end
end
```

Every open page appends the comment. A page that was offline gets the comments it missed when it reconnects. Any Turbo Stream action works: `replace`, `remove`, `refresh`, `replace` with `attributes: {method: :morph}`, and your own custom actions.

## A background job with a progress bar

The page makes a stream for the job and listens on it:

```ruby
def new
  @stream = Sossego::Stream.random
end

def create
  stream = Sossego::Stream.verified_from_url(params[:stream_url]) or return head(:forbidden)
  ImportJob.perform_later(file_id: params[:file_id], stream_id: stream.id)
  head :accepted
end
```

```erb
<div data-controller="sossego" data-sossego-url-value="<%= sossego_signed_stream_path(@stream) %>">
  <div data-sossego-progress hidden><span data-sossego-progress-text></span></div>
</div>

<%= form_with url: imports_path do |f| %>
  <%= hidden_field_tag :stream_url, sossego_signed_stream_path(@stream) %>
  ...
<% end %>
```

The job reports to it:

```ruby
class ImportJob < ApplicationJob
  include Sossego::PublishingHelpers

  def perform(file_id:, stream_id:)
    stream.publish_progress("Reading the file...")
    rows = Import.new(file_id).run { |n| stream.publish_progress("Imported #{n} rows...") }
    stream.publish_turbo_stream(:replace, target: "summary", partial: "imports/summary", locals: {rows:})
  end
end
```

The progress element shows each message. When the job finishes, or fails with an error message, the bar settles. Its `data-sossego-progress` attribute is set to `working`, `warning`, `error` or `finished`; style it with attribute selectors. The job can also fill in a form (`stream.publish_field_prefill`) or send the browser elsewhere (`stream.publish_visit`). Those helpers are on every `Sossego::Stream`, so a controller or a console can publish the same events.

## One-off named streams

Most streams are named after a record and live as long as it does: `account:42:live`, the account's live updates. A one-off stream exists for a single piece of work. A random name is enough to identify it, and nobody needs it once the work is done.

```ruby
stream = Sossego::Stream.random              # "task:k7p2qd9z4m1x:progress"
Sossego::Stream.random(:tokens, namespace: :generation)
```

The page that made it is the only one that knows its name. Hand it to the browser signed, and the engine serves it with no controller of your own: `sossego_signed_stream_path(stream)` gives `/sossego/streams/task:k7p2qd9z4m1x:progress?sig=...`. A signature can expire (`stream.signature(expires_in: 1.hour)`). When the browser sends the URL back, for example with the form that starts the job, `Sossego::Stream.verified_from_url` returns the stream, or nil if the signature doesn't match.

The work may start before the browser connects, as when a job is enqueued and the response redirects to a page that waits for it. That's fine: a connection without a cursor replays the stream from its first event, so nothing published in between is lost. Add `data-sossego-await-task-value="true"` to the waiting element, and the page reports a job that never sends anything.

When the work is over, close the stream, so every page reading it stops listening and the server stops holding a thread for it:

```ruby
stream.publish_close(reason: "finished")

class ImportJob < ApplicationJob
  include Sossego::PublishingHelpers
  self.sossego_close_stream = true   # closes the stream after the job's last event, success or failure
end
```

Don't close a stream that a page keeps for more than one task: after a close, nobody hears anything published to it. Old events are deleted by `Sossego::PruneJob` with everything else.

## Why Sossego and not ActionCable?

*To be written.*

## More

- [MANUAL.md](MANUAL.md): publishing in detail, serving and configuring streams, jobs, the JavaScript client, React and Inertia, how events are stored, and why SSE.
- [WIRE_FORMAT.md](WIRE_FORMAT.md): what goes over the wire, for writing another client or server.
- The dummy app in `test/dummy` is a set of runnable demos: `cd test/dummy && bin/rails db:prepare && bin/rails server`.

## License

MIT, see [LICENSE.md](LICENSE.md).
