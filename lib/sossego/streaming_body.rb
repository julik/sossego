# frozen_string_literal: true

module Sossego
  # A Rack response body that streams SSE frames from a source.
  #
  # Implements `#each` to yield SSE-formatted strings. Rack iterates the
  # body and writes each yielded chunk to the socket. **No
  # `ActionController::Live`** — this is just a standard Rack body.
  #
  # ## Source contract (pull-based)
  #
  # The source is expected to respond to:
  #
  # - `fetch_after(cursor)` → `[events, head]`. `cursor` is an opaque
  #   string, or nil for none. `events` is an ordered array of objects
  #   responding to `seq` (the cursor, a string), `sseq`, `event_name`,
  #   `pld` (see {Source::EventTuple}). `head` is the stream's head cursor
  #   as a string — used as the lag hint in envelopes and pings.
  # - `stream_id` — string identifier for the stream (the envelope's
  #   `sid`).
  # - `head` → the stream's head cursor, a string. Only asked for, once per
  #   connection, when `ping_first` or `max_backlog` is set.
  # - `backlog_start(cursor, max_backlog)` → the cursor to start from so at
  #   most `max_backlog` events after `cursor` are replayed. Only asked for
  #   when `max_backlog` is set and the client sent a cursor.
  # - `close` (optional) — release any held resources.
  #
  # The body owns the polling loop. Between fetches it emits pings
  # (every {HEARTBEAT_INTERVAL_S}s of quiet) and checks the
  # {MAX_CONNECTED_S} deadline. This is the part that didn't work in
  # the previous yield-based contract: a quiet source would sleep
  # forever and the body could never tick.
  #
  # ## Stream budget
  #
  # Every body that is streaming holds one slot of a process-wide count
  # ({.open_streams}), because it also holds one server thread for as
  # long as it is connected. With `max_open_streams` set, a body that
  # finds the count at that number does not stream: it yields one
  # `over_budget` refusal ({Sossego.format_close_frame}, no position)
  # and ends.
  #
  # The slot is taken as the first step of {#each} and given back in
  # its `ensure`, under one lock. So a burst of simultaneous connects
  # cannot exceed the budget, and a body Rack never iterates never
  # holds a slot.
  #
  # ## Lifecycle terminates on the earliest of:
  #
  # 1. Puma signals shutdown ({Sossego.puma_shutting_down?})
  # 2. No free slot under `max_open_streams` — one close frame
  # 3. {MAX_CONNECTED_S} elapsed — client reconnects via
  #    EventSource's native `Last-Event-ID` mechanism, source resumes
  # 4. The source yields a row named `close` (stored through
  #    {Stream#publish_close}): it goes out as a `close` frame with its
  #    position, and the body stops
  # 5. The client disconnects — `IOError`/`EPIPE`/`ECONNRESET` raised
  #    by `yield`; rescued cleanly
  #
  # Every other row goes out as a `sossego` frame
  # ({Sossego.format_event_frame}); heartbeats as `ping` frames
  # ({Sossego.format_ping_frame}).
  #
  # @example What a connection that reaches a stored close receives
  #   retry: 3000
  #
  #   event: sossego
  #   id: 30
  #   data: {"fmt": "ejson", "evt": "progress", "seq": "30", "sseq": 11, "head": "31", "sid": "task:7:progress", "pld": {"done": 5}}
  #
  #   event: close
  #   id: 31
  #   data: {"fmt": "ejson", "evt": "close", "seq": "31", "sseq": 12, "head": "31", "sid": "task:7:progress", "pld": {"reason": "finished"}}
  #
  # (Envelopes shown on one line; on the wire they are pretty-printed, one
  # `data:` line per line of JSON.)
  #
  # @example A controller that only names the stream
  #   class InboxStreamsController < Sossego::StreamsController
  #     def sossego_stream
  #       Sossego::Stream.for(Current.account, :inbox)
  #     end
  #   end
  #
  # @example A bounded, self-describing stream
  #   Sossego::StreamingBody.new(
  #     source: Sossego::Source.new(stream),
  #     last_id: request.headers["Last-Event-ID"],
  #     max_open_streams: 16,     # the 17th connection gets `over_budget`
  #     ping_first: true,         # first frame says where the stream is
  #     max_backlog: 100,         # never replay more than 100 events
  #     poll_interval_s: 1,
  #     retry_ms: 2_000..5_000    # each connection draws its own
  #   )
  class StreamingBody
    MAX_CONNECTED_S = 30
    HEARTBEAT_INTERVAL_S = 10
    POLL_INTERVAL_S = 0.25
    RETRY_MS = 3_000

    # Reason in the close frame a connection over the budget receives.
    OVER_BUDGET = "over_budget"

    @open_streams = 0
    @slots = Mutex.new

    class << self
      # @return [Integer] bodies this process is streaming right now
      attr_reader :open_streams

      # Takes a slot unless `max` are taken already.
      #
      # @api private
      # @param max [Integer, nil] nil for no limit
      # @return [Integer, nil] the new count, or nil when no slot is free
      def reserve_slot(max)
        @slots.synchronize do
          next nil if max && @open_streams >= max

          @open_streams += 1
        end
      end

      # @api private
      # @return [Integer] the new count
      def release_slot
        @slots.synchronize { @open_streams -= 1 }
      end
    end

    # @param source [#fetch_after, #stream_id, #head, #close]
    # @param last_id [String, nil] resume cursor (typically the
    #   `Last-Event-ID` request header), opaque; nil or blank for none
    # @param logger [Logger]
    # @param max_connected_s [Numeric] override only for tests
    # @param heartbeat_interval_s [Numeric] override only for tests
    # @param poll_interval_s [Numeric] seconds to sleep after a poll that
    #   found nothing
    # @param retry_ms [Numeric, Range] reconnect interval (ms) advertised
    #   to the browser via the SSE `retry:` field. From a Range each
    #   connection draws its own value, so the clients of a restarted
    #   server do not all come back in the same instant.
    # @param max_open_streams [Integer, nil] the process's stream budget
    #   (see "Stream budget" above); nil for no limit
    # @param open_streams_gauge [#call, nil] called with the new
    #   {.open_streams} count each time this body takes or frees a slot
    # @param on_over_budget [#call, nil] called with no arguments when this
    #   body is refused for lack of a slot, before its close frame goes out
    # @param ping_first [Boolean] send a ping carrying the head as the
    #   first frame after `retry:`, before the first poll. It tells the
    #   client where the stream is and proves the connection delivers.
    # @param max_backlog [Integer, nil] bounds where a connection starts.
    #   With it set, a connection with no cursor starts at the head
    #   instead of replaying the stream from its first event, and a
    #   cursor with more than this many events after it starts this many
    #   events behind the head ({Source#backlog_start}). Nil keeps the
    #   cursor as given; with none, the stream replays from its first
    #   retained event.
    # @param clock [#call] zero-arg callable returning a monotonic
    #   timestamp; tests inject a controlled clock
    # @param compress_above_bytes [Integer, nil] gzip an event whose `pld`
    #   is at least this many bytes of JSON and is not gzipped already: an
    #   `ejson`, `text` or `bytes` row goes out as `gz:ejson`, `gz:text` or
    #   `gz:bytes`. Nil never compresses. The bundled client decodes all of
    #   them.
    # @param sleeper [#call] one-arg callable that sleeps for the given
    #   number of seconds; tests inject a no-op
    def initialize(source:, last_id: nil, logger: (Rails.logger if defined?(Rails)),
      max_connected_s: MAX_CONNECTED_S,
      heartbeat_interval_s: HEARTBEAT_INTERVAL_S,
      poll_interval_s: POLL_INTERVAL_S,
      retry_ms: RETRY_MS,
      max_open_streams: nil,
      open_streams_gauge: nil,
      on_over_budget: nil,
      ping_first: false,
      max_backlog: nil,
      compress_above_bytes: nil,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      sleeper: ->(s) { sleep(s) })
      @source = source
      @last_id = last_id
      @logger = logger
      @max_connected_s = max_connected_s
      @heartbeat_interval_s = heartbeat_interval_s
      @poll_interval_s = poll_interval_s
      @retry_ms = retry_ms
      @max_open_streams = max_open_streams
      @open_streams_gauge = open_streams_gauge
      @on_over_budget = on_over_budget
      @ping_first = ping_first
      @max_backlog = max_backlog
      @compress_above_bytes = compress_above_bytes
      @clock = clock
      @sleeper = sleeper
    end

    # Rack body interface.
    def each
      return if Sossego.puma_shutting_down?

      stream_id = @source.respond_to?(:stream_id) ? @source.stream_id.to_s : ""

      open_streams = self.class.reserve_slot(@max_open_streams)
      unless open_streams
        @on_over_budget&.call
        yield Sossego.format_close_frame(reason: OVER_BUDGET)
        return
      end
      @open_streams_gauge&.call(open_streams)

      connected_at = @clock.call
      last_yield_at = @clock.call

      # Tell the browser how long to wait before native auto-reconnect.
      yield "retry: #{@retry_ms.is_a?(Range) ? rand(@retry_ms) : @retry_ms}\n\n"

      cursor = @last_id.presence&.to_s
      if @ping_first || @max_backlog
        head = @source.head.to_s
        if @max_backlog
          cursor = cursor ? @source.backlog_start(cursor, @max_backlog) : head
        end

        if @ping_first
          yield Sossego.format_ping_frame(head: head)
          last_yield_at = @clock.call
        end
      end

      loop do
        return if Sossego.puma_shutting_down?
        return if (@clock.call - connected_at) >= @max_connected_s

        events, head = @source.fetch_after(cursor)

        # A stored close ends the stream: nothing after it goes out.
        close_at = events.index { |ev| ev.event_name == Sossego::SSE_EVENT_CLOSE }
        events.first(close_at || events.length).each do |ev|
          yield Sossego.format_event_frame(compressed(ev), head: head, sid: stream_id)
          last_yield_at = @clock.call
          cursor = ev.seq.to_s
        end

        if close_at
          close = events[close_at]
          reason = close.pld["reason"] if close.pld.is_a?(Hash)
          yield Sossego.format_close_frame(reason: reason, seq: close.seq, sseq: close.sseq, head: head, sid: stream_id)
          return
        end

        # Heartbeat: emit a ping if we've been quiet too long. Keeps
        # the JS-side stall timer reset and TCP alive through proxies.
        if (@clock.call - last_yield_at) >= @heartbeat_interval_s
          yield Sossego.format_ping_frame(head: head)
          last_yield_at = @clock.call
        end

        @sleeper.call(@poll_interval_s) if events.empty?
      end
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET => e
      @logger&.info("Sossego streaming body: client disconnected (#{e.class.name})")
    ensure
      if open_streams
        open_streams = self.class.release_slot
        @open_streams_gauge&.call(open_streams)
      end

      if @source.respond_to?(:close)
        begin
          @source.close
        rescue => e
          Sossego.report_error(e, message: "Sossego streaming body: source.close raised", logger: @logger, stream_id: stream_id)
        end
      end
    end

    private

    def compressed(event)
      return event unless @compress_above_bytes

      fmt = Sossego.fmt_of(event)
      gz_fmt = "#{Sossego::GZIP_PREFIX}#{fmt}"
      return event unless Sossego.encoders.key?(gz_fmt) && Sossego.decoders.key?(fmt)
      return event if JSON.generate(event.pld).bytesize < @compress_above_bytes

      value = Sossego.decoders.fetch(fmt).call(event.pld)
      Source::EventTuple.new(event.seq, event.sseq, event.event_name, Sossego.encoders.fetch(gz_fmt).call(value), gz_fmt)
    end
  end
end
