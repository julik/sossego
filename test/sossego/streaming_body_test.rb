require "test_helper"

class Sossego::StreamingBodyTest < ActiveSupport::TestCase
  EventTuple = Struct.new(:seq, :sseq, :event_name, :pld)

  # Test source that returns canned fetches in sequence. Each call to
  # fetch_after returns the next [events, head] tuple from the queue.
  # Once exhausted, subsequent calls return [[], last_head] — mirroring
  # production source behavior where the head is sticky across polls.
  #
  # `head` is what the body reads once per connection when it sends a first
  # ping or bounds the cursor; `cursors` records what each fetch asked for,
  # and `backlog_starts` what each backlog_start was asked, answering
  # `backlog_start_answer` (the cursor itself when that is nil).
  class FakeSource
    attr_reader :closed_count, :stream_id, :head, :cursors, :backlog_starts

    def initialize(fetches, stream_id: "test:s:m", head: "0", backlog_start_answer: nil)
      @fetches = fetches.dup
      @stream_id = stream_id
      @head = head
      @backlog_start_answer = backlog_start_answer
      @cursors = []
      @backlog_starts = []
      @closed_count = 0
      @last_head = "0"
    end

    def fetch_after(cursor)
      @cursors << cursor
      tuple = @fetches.shift
      if tuple
        @last_head = tuple[1]
        tuple
      else
        [[], @last_head]
      end
    end

    def backlog_start(cursor, max_backlog)
      @backlog_starts << [cursor, max_backlog]
      @backlog_start_answer || cursor
    end

    def close
      @closed_count += 1
    end
  end

  # Manual monotonic clock — tests advance it deterministically.
  class FakeClock
    def initialize(start = 0.0)
      @t = start
    end

    def call = @t
    def advance(seconds) = @t += seconds
  end

  # No-op sleeper for tests so the body's poll loop doesn't actually
  # block. Tests that care about sleep advance @clock instead.
  NO_SLEEP = ->(_s) {}

  # ----- helpers -----

  def event_chunks(chunks)
    chunks.drop_while { |c| c.start_with?("retry:") }
  end

  def envelope_of(chunk)
    data_lines = chunk.lines.select { |l| l.start_with?("data: ") }
    Sossego.decode_frame(data_lines.map { |l| l.sub(/\Adata: /, "").chomp }.join("\n"))
  end

  # Bound the poll loop with a fake clock that runs past
  # MAX_CONNECTED_S whenever the body checks the deadline. Effectively
  # one polling pass.
  def one_pass(events_and_head)
    clock = FakeClock.new(0.0)
    source = FakeSource.new([events_and_head])
    body = Sossego::StreamingBody.new(
      source: source,
      last_id: nil, logger: nil,
      max_connected_s: 1,
      heartbeat_interval_s: 1_000,  # disable heartbeat for tests focused on event framing
      poll_interval_s: 0,
      clock: clock,
      sleeper: ->(_s) { clock.advance(2) }  # advancing past max_connected_s ends the loop
    )

    chunks = []
    body.each { |c| chunks << c }
    chunks
  end

  # One polling pass over a quiet source, with the given body options.
  def quiet_pass(source = FakeSource.new([]), **options)
    clock = FakeClock.new(0.0)
    body = Sossego::StreamingBody.new(
      source: source, logger: nil,
      max_connected_s: 1, heartbeat_interval_s: 1_000, poll_interval_s: 0,
      clock: clock, sleeper: ->(_s) { clock.advance(2) },
      **options
    )

    chunks = []
    body.each { |c| chunks << c }
    chunks
  end

  def open_streams
    Sossego::StreamingBody.open_streams
  end

  # ----- shape of the wire -----

  test "yields the retry directive as the first chunk" do
    chunks = one_pass([[], "0"])
    assert_equal "retry: 3000\n\n", chunks.first
  end

  test "respects custom retry_ms" do
    clock = FakeClock.new(0.0)
    source = FakeSource.new([[[], "0"]])
    body = Sossego::StreamingBody.new(
      source: source, last_id: nil, logger: nil,
      retry_ms: 5_000,
      max_connected_s: 1, heartbeat_interval_s: 1_000, poll_interval_s: 0,
      clock: clock,
      sleeper: ->(_) { clock.advance(2) }  # jump past deadline
    )

    chunks = []
    body.each { |c| chunks << c }
    assert_equal "retry: 5000\n\n", chunks.first
  end

  test "a retry_ms range gives each connection its own value inside the range" do
    retries = Array.new(20) { quiet_pass(retry_ms: 2_000..5_000).first[/\Aretry: (\d+)\n\n\z/, 1].to_i }

    assert retries.all? { |ms| (2_000..5_000).cover?(ms) }, "every retry must fall in the range, got #{retries}"
    assert_operator retries.uniq.length, :>, 1, "connections must not all share one retry value"
  end

  # ----- first ping -----

  test "ping_first sends a ping carrying the head right after retry, before the first sleep" do
    clock = FakeClock.new(0.0)
    chunks = []
    chunks_before_first_sleep = nil
    body = Sossego::StreamingBody.new(
      source: FakeSource.new([], head: "42"), logger: nil, ping_first: true,
      max_connected_s: 1, heartbeat_interval_s: 1_000, poll_interval_s: 0,
      clock: clock,
      sleeper: ->(_s) {
        chunks_before_first_sleep ||= chunks.dup
        clock.advance(2)
      }
    )

    body.each { |c| chunks << c }

    assert_equal 2, chunks_before_first_sleep.length
    assert_match(/\Aretry: \d+\n\n\z/, chunks_before_first_sleep[0])
    assert chunks_before_first_sleep[1].start_with?("event: ping\n")
    assert_match(/"head": "42"/, chunks_before_first_sleep[1])
  end

  test "without ping_first the first frame after retry is the first event" do
    chunks = one_pass([[EventTuple.new("1", 1, "entity", {})], "1"])

    assert_includes chunks[1], "event: sossego\nid: 1"
  end

  # ----- starting cursor -----

  test "without max_backlog a connection with no cursor polls from the start" do
    source = FakeSource.new([], head: "1000")

    quiet_pass(source, last_id: nil)

    assert_nil source.cursors.first
  end

  test "a blank last_id means no cursor" do
    source = FakeSource.new([], head: "1000")

    quiet_pass(source, last_id: "", max_backlog: 100)

    assert_equal "1000", source.cursors.first
    assert_empty source.backlog_starts
  end

  test "max_backlog starts a connection with no cursor at the head" do
    source = FakeSource.new([], head: "1000")

    quiet_pass(source, last_id: nil, max_backlog: 100)

    assert_equal "1000", source.cursors.first
  end

  test "max_backlog asks the source where a cursor should start and polls from there" do
    source = FakeSource.new([], head: "1000", backlog_start_answer: "900")

    quiet_pass(source, last_id: "500", max_backlog: 100)

    assert_equal [["500", 100]], source.backlog_starts
    assert_equal "900", source.cursors.first
  end

  test "the cursor is passed on as the opaque string it arrived as" do
    source = FakeSource.new([])

    quiet_pass(source, last_id: "0190a8e2-7c3b-7d4e-8f00-000000000001")

    assert_equal "0190a8e2-7c3b-7d4e-8f00-000000000001", source.cursors.first
  end

  test "the cursor advances to each delivered event's seq" do
    source = FakeSource.new([[[EventTuple.new("7", 1, "entity", {}), EventTuple.new("19", 2, "entity", {})], "19"]])
    clock = FakeClock.new(0.0)
    body = Sossego::StreamingBody.new(
      source: source, logger: nil,
      max_connected_s: 3, heartbeat_interval_s: 1_000, poll_interval_s: 1,
      clock: clock, sleeper: ->(s) { clock.advance(s) }
    )

    body.each { |_| }

    assert_equal [nil, "19"], source.cursors.first(2)
  end

  test "polls with the configured interval" do
    slept = []
    clock = FakeClock.new(0.0)
    body = Sossego::StreamingBody.new(
      source: FakeSource.new([]), logger: nil,
      max_connected_s: 3, heartbeat_interval_s: 1_000, poll_interval_s: 1,
      clock: clock,
      sleeper: ->(seconds) {
        slept << seconds
        clock.advance(seconds)
      }
    )

    body.each { |_| }

    assert_equal [1, 1, 1], slept
  end

  # ----- stream budget -----

  test "a body that is never iterated holds no slot" do
    before = open_streams

    Sossego::StreamingBody.new(source: FakeSource.new([]), logger: nil, max_open_streams: 1)

    assert_equal before, open_streams
  end

  test "holds one slot while it streams and reports the count each time it changes" do
    before = open_streams
    while_streaming = nil
    reported = []
    clock = FakeClock.new(0.0)
    body = Sossego::StreamingBody.new(
      source: FakeSource.new([]), logger: nil,
      max_open_streams: before + 1, open_streams_gauge: ->(count) { reported << count },
      max_connected_s: 1, heartbeat_interval_s: 1_000, poll_interval_s: 0,
      clock: clock,
      sleeper: ->(_s) {
        while_streaming = open_streams
        clock.advance(2)
      }
    )

    body.each { |_| }

    assert_equal before + 1, while_streaming
    assert_equal before, open_streams
    assert_equal [before + 1, before], reported
  end

  test "refuses with one over_budget close frame when every slot is taken, and leaves the count alone" do
    before = open_streams
    budget = before + 1
    refused_chunks = nil
    count_after_refusal = nil
    reported_by_refused = []
    clock = FakeClock.new(0.0)
    # The holder is mid-stream, asleep between polls, when the second
    # connection arrives.
    holder = Sossego::StreamingBody.new(
      source: FakeSource.new([]), logger: nil, max_open_streams: budget,
      max_connected_s: 1, heartbeat_interval_s: 1_000, poll_interval_s: 0,
      clock: clock,
      sleeper: ->(_s) {
        refused_chunks = quiet_pass(max_open_streams: budget, open_streams_gauge: ->(count) { reported_by_refused << count })
        count_after_refusal = open_streams
        clock.advance(2)
      }
    )

    holder.each { |_| }

    assert_equal 1, refused_chunks.length, "a refusal is one frame, with no retry directive"
    frame = refused_chunks.first
    assert frame.start_with?("event: close\n")
    assert_no_match(/^id:/, frame)
    assert_equal({"fmt" => "ejson", "evt" => "close", "pld" => {"reason" => "over_budget"}}, envelope_of(frame))
    assert_equal budget, count_after_refusal, "a refused connection must not hold or free a slot"
    assert_empty reported_by_refused
    assert_equal before, open_streams
  end

  test "calls on_over_budget once for a refused connection, before its close frame" do
    order = []
    body = Sossego::StreamingBody.new(
      source: FakeSource.new([]), logger: nil,
      max_open_streams: open_streams, on_over_budget: -> { order << :on_over_budget }
    )

    body.each { |chunk| order << envelope_of(chunk).dig("pld", "reason") }

    assert_equal [:on_over_budget, "over_budget"], order
  end

  test "never calls on_over_budget for a connection that gets a slot" do
    calls = 0

    chunks = quiet_pass(max_open_streams: open_streams + 1, on_over_budget: -> { calls += 1 })

    assert_match(/\Aretry: \d+\n\n\z/, chunks.first)
    assert_equal 0, calls
  end

  test "more connections than the budget at the same time: exactly the budget stream and the rest are refused" do
    before = open_streams
    budget = 3
    connections = 8
    start = Queue.new
    parked = Queue.new
    release = Queue.new
    finished = Queue.new
    released = false

    threads = Array.new(connections) do
      Thread.new do
        body = Sossego::StreamingBody.new(
          source: FakeSource.new([]), logger: nil, max_open_streams: before + budget,
          max_connected_s: 1, heartbeat_interval_s: 1_000, poll_interval_s: 0,
          clock: -> { released ? 100.0 : 0.0 },
          sleeper: ->(_s) {
            parked << true
            release.pop
          }
        )
        chunks = []
        start.pop
        body.each { |c| chunks << c }
        finished << chunks
      end
    end

    connections.times { start << true }
    # The admitted connections park in their first sleep, each holding a
    # slot; the refused ones finish on their own.
    budget.times { assert parked.pop(timeout: 5), "expected #{budget} connections to be streaming" }
    refused = Array.new(connections - budget) { finished.pop(timeout: 5) }
    count_while_streaming = open_streams
    nobody_else_finished = finished.empty?

    released = true
    budget.times { release << true }
    streamed = Array.new(budget) { finished.pop(timeout: 5) }
    threads.each { |thread| thread.join(5) }

    assert_equal before + budget, count_while_streaming
    assert nobody_else_finished, "an admitted connection must keep streaming until it is released"
    refused.each do |chunks|
      assert_equal 1, chunks.length
      assert_equal "over_budget", envelope_of(chunks.first).dig("pld", "reason")
    end
    streamed.each { |chunks| assert_match(/\Aretry: \d+\n\n\z/, chunks.first) }
    assert_equal before, open_streams
  end

  test "gives the slot back when the client disconnects" do
    before = open_streams
    body = Sossego::StreamingBody.new(
      source: FakeSource.new([[[EventTuple.new("1", 1, "entity", {})], "1"]]), logger: nil, max_open_streams: before + 1,
      max_connected_s: 100, heartbeat_interval_s: 1_000, poll_interval_s: 0,
      sleeper: NO_SLEEP
    )

    body.each { |_| raise IOError, "stream closed" }

    assert_equal before, open_streams
  end

  test "gives the slot back when the source raises" do
    before = open_streams
    source = FakeSource.new([])
    def source.fetch_after(_cursor)
      raise "database is down"
    end
    body = Sossego::StreamingBody.new(
      source: source, logger: nil, max_open_streams: before + 1,
      max_connected_s: 100, heartbeat_interval_s: 1_000, poll_interval_s: 0,
      sleeper: NO_SLEEP
    )

    error = assert_raises(RuntimeError) { body.each { |_| } }

    assert_equal "database is down", error.message
    assert_equal before, open_streams
  end

  test "yields a framed envelope per event from the source" do
    chunks = one_pass([
      [
        EventTuple.new("1", 1, "entity", {"id" => 7}),
        EventTuple.new("2", 2, "fact", {"name" => "x", "value" => 1})
      ],
      "2"
    ])
    events = event_chunks(chunks)

    assert_includes events[0], "event: sossego\nid: 1"
    env1 = envelope_of(events[0])
    assert_equal "entity", env1["evt"]
    assert_equal "1", env1["seq"]
    assert_equal 1, env1["sseq"]
    assert_equal "2", env1["head"]
    assert_equal "test:s:m", env1["sid"]
    assert_equal({"id" => 7}, env1["pld"])

    assert_includes events[1], "event: sossego\nid: 2"
    env2 = envelope_of(events[1])
    assert_equal "fact", env2["evt"]
    assert_equal "2", env2["seq"]
    assert_equal 2, env2["sseq"]
  end

  test "head from fetch flows into envelope.head" do
    chunks = one_pass([[EventTuple.new("1", 1, "entity", {})], "99"])
    env = envelope_of(event_chunks(chunks).first)
    assert_equal "99", env["head"]
  end

  # ----- stored close -----

  test "a stored close row goes out as a close frame with its position, and the body stops" do
    chunks = one_pass([
      [
        EventTuple.new("1", 1, "entity", {"id" => 7}),
        EventTuple.new("2", 2, "close", {"reason" => "finished"}),
        EventTuple.new("3", 3, "entity", {"id" => 99})  # never yielded
      ],
      "3"
    ])
    events = event_chunks(chunks)

    assert_equal 2, events.length
    assert events[1].start_with?("event: close\nid: 2\n")
    assert_equal(
      {"fmt" => "ejson", "evt" => "close", "seq" => "2", "sseq" => 2, "head" => "3", "sid" => "test:s:m", "pld" => {"reason" => "finished"}},
      envelope_of(events[1])
    )
    refute(chunks.any? { |c| c.include?(%("id": 99)) })
  end

  test "no application event name is terminal" do
    chunks = one_pass([
      [
        EventTuple.new("1", 1, "content", "hello"),
        EventTuple.new("2", 2, "message_complete", {"id" => 42}),
        EventTuple.new("3", 3, "content", "still delivered")
      ],
      "3"
    ])

    assert_equal 3, event_chunks(chunks).length
    assert(event_chunks(chunks).all? { |c| c.start_with?("event: sossego\n") })
  end

  # ----- source.close -----

  test "calls source.close exactly once when iteration completes" do
    source = FakeSource.new([[[], "0"]])
    body = Sossego::StreamingBody.new(
      source: source, last_id: nil, logger: nil,
      max_connected_s: 0,  # exit immediately
      heartbeat_interval_s: 1_000, poll_interval_s: 0,
      sleeper: NO_SLEEP, clock: -> { 999 }
    )
    body.each { |_| }
    assert_equal 1, source.closed_count
  end

  test "calls source.close when a stored close ends the loop" do
    source = FakeSource.new([[[EventTuple.new("1", 1, "close", {})], "1"]])
    body = Sossego::StreamingBody.new(
      source: source, last_id: nil, logger: nil,
      max_connected_s: 100, heartbeat_interval_s: 1_000, poll_interval_s: 0,
      sleeper: NO_SLEEP
    )
    body.each { |_| }
    assert_equal 1, source.closed_count
  end

  # ----- client disconnect -----

  test "rescues IOError from yield (client disconnect) and closes source" do
    source = FakeSource.new([[[EventTuple.new("1", 1, "entity", {})], "1"]])
    body = Sossego::StreamingBody.new(
      source: source, last_id: nil, logger: nil,
      max_connected_s: 100, heartbeat_interval_s: 1_000, poll_interval_s: 0,
      sleeper: NO_SLEEP
    )

    assert_nothing_raised do
      body.each { |_| raise IOError, "stream closed" }
    end
    assert_equal 1, source.closed_count
  end

  test "rescues Errno::EPIPE" do
    source = FakeSource.new([[[EventTuple.new("1", 1, "entity", {})], "1"]])
    body = Sossego::StreamingBody.new(
      source: source, last_id: nil, logger: nil,
      max_connected_s: 100, heartbeat_interval_s: 1_000, poll_interval_s: 0,
      sleeper: NO_SLEEP
    )

    assert_nothing_raised do
      body.each { |_| raise Errno::EPIPE }
    end
  end

  # ----- deadline & shutdown -----

  test "exits when MAX_CONNECTED_S elapses" do
    clock = FakeClock.new(0.0)
    source = FakeSource.new([])  # always returns [[], "0"]
    body = Sossego::StreamingBody.new(
      source: source, last_id: nil, logger: nil,
      max_connected_s: 30, heartbeat_interval_s: 1_000, poll_interval_s: 0,
      clock: clock,
      sleeper: ->(_) { clock.advance(31) }  # one sleep past the deadline
    )

    chunks = []
    body.each { |c| chunks << c }

    # Should have just the retry frame and exited.
    assert_equal 1, chunks.length
    assert_match(/\Aretry:/, chunks[0])
  end

  test "exits when PumaShutdown signals shutting down" do
    skip "Puma::Server not loaded" unless defined?(Puma::Server)

    fake = Object.new
    def fake.shutting_down?
      true
    end

    source = FakeSource.new([[[EventTuple.new("1", 1, "entity", {})], "1"]])
    body = Sossego::StreamingBody.new(
      source: source, last_id: nil, logger: nil,
      max_connected_s: 100, heartbeat_interval_s: 1_000, poll_interval_s: 0,
      sleeper: NO_SLEEP
    )

    chunks = []
    Puma::Server.stub(:current, fake) do
      body.each { |c| chunks << c }
    end

    assert_equal 0, chunks.length, "shutting-down Puma yields nothing"
  end

  test "ends at the next poll when Puma starts shutting down mid-stream, and gives the slot back" do
    skip "Puma::Server not loaded" unless defined?(Puma::Server)

    before = open_streams
    shutting_down = false
    server = Object.new
    server.define_singleton_method(:shutting_down?) { shutting_down }
    held_while_streaming = nil
    slept = 0
    clock = FakeClock.new(0.0)
    source = FakeSource.new([])
    # Left alone, this body would poll five times before its deadline.
    body = Sossego::StreamingBody.new(
      source: source, logger: nil, max_open_streams: before + 1,
      max_connected_s: 5, heartbeat_interval_s: 1_000, poll_interval_s: 1,
      clock: clock,
      sleeper: ->(seconds) {
        slept += 1
        held_while_streaming = open_streams
        clock.advance(seconds)
        shutting_down = true
      }
    )

    chunks = []
    Puma::Server.stub(:current, server) do
      body.each { |c| chunks << c }
    end

    assert_equal ["retry: 3000\n\n"], chunks
    assert_equal 1, slept, "the body must end at the first poll after shutdown began, not at its deadline"
    assert_equal 1, source.cursors.length
    assert_equal before + 1, held_while_streaming
    assert_equal before, open_streams
    assert_equal 1, source.closed_count
  end

  # ----- heartbeat / pings -----

  test "emits a ping event when no source events arrive within HEARTBEAT_INTERVAL_S" do
    # Quiet source. Clock jumps past heartbeat threshold on first sleep.
    clock = FakeClock.new(0.0)
    source = FakeSource.new([])
    body = Sossego::StreamingBody.new(
      source: source, last_id: nil, logger: nil,
      max_connected_s: 60, heartbeat_interval_s: 10, poll_interval_s: 0,
      clock: clock,
      sleeper: ->(_) {
        # Advance past the heartbeat threshold once, then past max
        # connected on the next sleep so the loop exits.
        clock.advance(11)
      }
    )

    chunks = []
    body.each { |c| chunks << c }

    # retry directive, then a ping (heartbeat threshold exceeded), then exit
    pings = chunks.select { |c| c.start_with?("event: ping") }
    assert pings.length >= 1, "expected at least one ping on a quiet stream"
    assert_match(/"head": "0"/, pings.first)
  end

  test "ping uses the head from the most recent fetch" do
    clock = FakeClock.new(0.0)
    source = FakeSource.new([[[], "42"]])
    body = Sossego::StreamingBody.new(
      source: source, last_id: nil, logger: nil,
      max_connected_s: 60, heartbeat_interval_s: 10, poll_interval_s: 0,
      clock: clock,
      sleeper: ->(_) { clock.advance(11) }
    )

    chunks = []
    body.each { |c| chunks << c }

    ping = chunks.find { |c| c.start_with?("event: ping") }
    assert_match(/"head": "42"/, ping)
  end

  test "events reset the heartbeat timer (no ping if events are flowing)" do
    clock = FakeClock.new(0.0)
    source = FakeSource.new([
      [[EventTuple.new("1", 1, "entity", {"a" => 1})], "1"]
    ])
    body = Sossego::StreamingBody.new(
      source: source, last_id: nil, logger: nil,
      max_connected_s: 60, heartbeat_interval_s: 10, poll_interval_s: 0,
      clock: clock,
      sleeper: ->(_) { clock.advance(60) }  # exit on first quiet poll
    )

    chunks = []
    body.each { |c| chunks << c }

    # The first pass yields the event; the second pass tries to fetch
    # again, finds nothing, but the heartbeat hasn't elapsed yet (we
    # just yielded), so no ping. Then the sleep advances past
    # max_connected_s.
    refute chunks.any? { |c| c.start_with?("event: ping") },
      "no ping should fire if events are flowing"
  end
end
