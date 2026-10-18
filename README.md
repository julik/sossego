# Sossego

*"Sossego, eu preciso de sossego" - Tim Maia, 1977*

Server-Sent Events for Rails, from a database table. You publish an event and it becomes a row. Each open stream polls for new rows and sends them to the browser, which resumes where it left off after a reconnect. No Redis, no WebSocket server, no `ActionController::Live`. Works on SQLite and PostgreSQL.

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
    html = ApplicationController.render(partial: "comments/comment", locals: {comment: self})
    Sossego::Stream.for(account, :live).publish("turbo_stream",
      ApplicationController.helpers.turbo_stream_action_tag(:append, target: "comments", template: html))
  end
end
```

Every open page appends the comment. A page that was offline gets the comments it missed when it reconnects.

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
  include Sossego::Reporting

  def perform(file_id:, stream_id:)
    publish_progress("Reading the file...")
    rows = Import.new(file_id).run { |n| publish_progress("Imported #{n} rows...") }
    publish_turbo_stream(render_summary(rows))
  end
end
```

The progress element shows each message. When the job finishes, or fails with an error message, the bar settles. Its `data-sossego-progress` attribute is set to `working`, `warning`, `error` or `finished`; style it with attribute selectors. The job can also fill in a form (`publish_field_prefill`) or send the browser elsewhere (`publish_visit`).

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
  include Sossego::Reporting
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
