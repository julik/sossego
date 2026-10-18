require "test_helper"

class Sossego::EventTest < ActiveSupport::TestCase
  setup do
    Sossego::Event.delete_all
  end

  test "publish writes a row with sseq 1 for a new stream" do
    ev = Sossego::Event.publish(stream_id: "test:1:foo", event_name: "entity", payload: {a: 1})
    assert_equal "test:1:foo", ev.stream_id
    assert_equal 1, ev.sseq
    assert_equal "entity", ev.event_name
    assert_equal '{"a":1}', ev.payload
  end

  test "publish assigns sseq 1, 2, 3 per stream with increasing ids" do
    events = Array.new(3) { Sossego::Event.publish(stream_id: "s:1", event_name: "entity", payload: "{}") }

    assert_equal [1, 2, 3], events.map(&:sseq)
    assert_equal events.map(&:id).sort, events.map(&:id)
    assert_equal 3, events.map(&:id).uniq.length
  end

  test "two streams interleave ids while each keeps a dense sseq" do
    published = %w[s:a s:b s:a s:b s:b s:a].map do |stream_id|
      Sossego::Event.publish(stream_id: stream_id, event_name: "x", payload: "{}")
    end

    ids = published.map(&:id)
    assert_equal ids.sort, ids, "ids are global and increase across streams"
    assert_equal [1, 2, 3], Sossego::Event.for_stream("s:a").order(:id).pluck(:sseq)
    assert_equal [1, 2, 3], Sossego::Event.for_stream("s:b").order(:id).pluck(:sseq)
    assert_equal [1, 1, 2, 2, 3, 3], published.map(&:sseq)
  end

  test "publish with after: equal to the current sseq appends" do
    Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}")
    Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}")

    event = Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}", after: 2)

    assert_equal 3, event.sseq
  end

  test "publish with after: other than the current sseq raises Conflict and writes nothing" do
    Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}")
    Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}")

    [1, 3].each do |after|
      assert_no_difference -> { Sossego::Event.count } do
        error = assert_raises(Sossego::Conflict) do
          Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}", after: after)
        end
        assert_match(/sseq 2, not #{after}/, error.message)
      end
    end
    assert_kind_of StandardError, Sossego::Conflict.new
  end

  test "publish with after: 0 appends to an empty stream and conflicts on a non-empty one" do
    first = Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}", after: 0)
    assert_equal 1, first.sseq

    assert_raises(Sossego::Conflict) do
      Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}", after: 0)
    end
    assert_equal 1, Sossego::Event.for_stream("s:1").count
  end

  test "a Conflict inside a caller's transaction leaves that transaction usable" do
    Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}")

    Sossego::Event.transaction do
      assert_raises(Sossego::Conflict) do
        Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}", after: 0)
      end
      Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}", after: 1)
    end

    assert_equal [1, 2], Sossego::Event.for_stream("s:1").order(:id).pluck(:sseq)
  end

  test "publish inside a caller's transaction gives the lock_timeout back afterwards" do
    skip_unless_postgres
    lock_timeout = -> { Sossego::Event.connection.select_value("SELECT current_setting('lock_timeout')") }
    before = lock_timeout.call

    Sossego::Event.transaction do
      Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}")
      assert_equal before, lock_timeout.call
    end
  end

  test "a stream pruned empty resumes with sseq 1 and an id above every old cursor" do
    old = Array.new(3) { Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}") }
    old_cursor = old.last.id.to_s
    Sossego::Event.for_stream("s:1").delete_all

    resumed = Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}")

    assert_equal 1, resumed.sseq
    assert_operator resumed.id, :>, old.last.id
    assert_equal [resumed.id], Sossego::Stream.new("s:1").events_after(old_cursor).pluck(:id)
  end

  test "publish stores a String as text, as it is, so it reads back as that string" do
    ev = Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "42")
    assert_equal ["text", "42"], [ev.fmt, ev.payload]

    tuple = Sossego::Source.new(Sossego::Stream.new("s:1")).fetch_after(nil).first.first
    assert_equal ["text", "42"], [tuple.fmt, tuple.pld]
    assert_equal "42", ev.reload.value
  end

  test "publish stores a String that looks like JSON as text too" do
    ev = Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: '{"a":1}')
    assert_equal '{"a":1}', ev.reload.value
  end

  test "publish stores anything else as ejson JSON text" do
    ev = Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: {a: [1, 2]})
    assert_equal ["ejson", '{"a":[1,2]}'], [ev.fmt, ev.payload]
    assert_equal({"a" => [1, 2]}, ev.reload.value)

    assert_equal ["ejson", "null"], Sossego::Event.publish(stream_id: "s:1", event_name: "x").then { [it.fmt, it.payload] }
  end

  test "publish stores bytes, and every gz: format, as base64" do
    bytes = Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "\x00\xFF".b, fmt: :bytes)
    assert_equal ["bytes", "AP8="], [bytes.fmt, bytes.payload]
    assert_equal "\x00\xFF".b, bytes.reload.value

    gz = Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: {a: 1}, fmt: "gz:ejson")
    assert_equal "gz:ejson", gz.fmt
    assert_equal '{"a":1}', Zlib.gunzip(Base64.strict_decode64(gz.payload))
    assert_equal({"a" => 1}, gz.reload.value)
  end

  test "publish refuses an unregistered fmt and non-UTF-8 text before touching the database" do
    assert_no_difference -> { Sossego::Event.count } do
      assert_raises(Sossego::UnknownEncoding) { Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: 1, fmt: "msgpack") }
      assert_raises(Sossego::UnknownEncoding) { Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "\xFF".b) }
    end
  end

  test "a row from before the fmt column reads as ejson, and one that is not JSON goes out as text" do
    json_row = Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: {a: 1})
    legacy = Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: {})
    legacy.update_columns(payload: "raw text, stored verbatim by an older version", fmt: "ejson")

    assert_equal [{"a" => 1}, "ejson"], json_row.reload.wire_pld_and_fmt
    assert_equal ["raw text, stored verbatim by an older version", "text"], legacy.reload.wire_pld_and_fmt
  end

  test "publish JSON-encodes Hash payloads" do
    ev = Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: {hello: "world"})
    assert_equal '{"hello":"world"}', ev.payload
  end

  test "for_stream scope filters by stream_id" do
    Sossego::Event.publish(stream_id: "s:a", event_name: "x", payload: "{}")
    Sossego::Event.publish(stream_id: "s:b", event_name: "x", payload: "{}")

    assert_equal 1, Sossego::Event.for_stream("s:a").count
    assert_equal 1, Sossego::Event.for_stream("s:b").count
  end

  test "after_cursor scope filters by id, taking the cursor as a string" do
    events = Array.new(3) { Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}") }

    assert_equal [events.last.id], Sossego::Event.for_stream("s:1").after_cursor(events[1].id.to_s).pluck(:id)
  end

  test "cursor_valid? accepts decimal ids and nothing else" do
    assert Sossego::Event.cursor_valid?("119")
    assert Sossego::Event.cursor_valid?("0")
    refute Sossego::Event.cursor_valid?("abc")
    refute Sossego::Event.cursor_valid?("")
    refute Sossego::Event.cursor_valid?("-1")
    refute Sossego::Event.cursor_valid?("1\n2")
  end

  test "lock_timeout_ms defaults to one second and is a class-level setting" do
    assert_equal 1_000, Sossego::Event.lock_timeout_ms
  end

  test "id_counter_value is at least every issued id" do
    event = Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}")

    assert_operator Sossego::Event.id_counter_value, :>=, event.id
  end

  test "publish raises ReservedEventName for every reserved name, before touching the database" do
    Sossego::RESERVED_EVENT_NAMES.each do |name|
      assert_no_queries do
        error = assert_raises(Sossego::ReservedEventName) do
          Sossego::Event.publish(stream_id: "s:1", event_name: name, payload: {})
        end
        assert_match(/#{name}/, error.message)
      end
    end
    assert_kind_of ArgumentError, Sossego::ReservedEventName.new
  end

  test "publish through the transport stores a close and nothing else reserved" do
    close = Sossego::Event.publish(stream_id: "s:1", event_name: "close", payload: {reason: "finished"}, transport: true)

    assert_equal "close", close.event_name
    assert_equal 1, close.sseq
    assert_equal '{"reason":"finished"}', close.payload
    (Sossego::RESERVED_EVENT_NAMES - ["close"]).each do |name|
      assert_raises(Sossego::ReservedEventName) do
        Sossego::Event.publish(stream_id: "s:1", event_name: name, payload: {}, transport: true)
      end
    end
  end

  test "validation rejects a reserved name written past publish" do
    event = Sossego::Event.new(stream_id: "s:1", sseq: 1, event_name: "close", payload: "{}", created_at: Time.current)

    refute event.valid?
    assert_includes event.errors[:event_name], "is reserved"
  end

  test "the unique (stream_id, sseq) index guards against a writer that bypassed the lock" do
    Sossego::Event.publish(stream_id: "s:1", event_name: "x", payload: "{}")

    assert_raises(ActiveRecord::RecordNotUnique) do
      Sossego::Event.create!(stream_id: "s:1", sseq: 1, event_name: "x", payload: "{}", created_at: Time.current)
    end
  end
end

# Publishers on separate connections, which the transactional tests above
# cannot have: there every thread shares the test's one connection.
class Sossego::EventConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  STREAM_ID = "concurrency:1:test"

  setup { Sossego::Event.for_stream(STREAM_ID).delete_all }
  teardown { Sossego::Event.for_stream(STREAM_ID).delete_all }

  test "concurrent publishes to one stream get a dense sseq in id order" do
    start = Queue.new
    threads = Array.new(4) do
      Thread.new do
        Sossego::Event.connection_pool.with_connection do
          start.pop
          10.times { Sossego::Event.publish(stream_id: STREAM_ID, event_name: "x", payload: "{}") }
        end
      end
    end
    4.times { start << true }
    threads.each(&:join)

    sseqs_in_id_order = Sossego::Event.for_stream(STREAM_ID).order(:id).pluck(:sseq)
    assert_equal (1..40).to_a, sseqs_in_id_order, "sseq must be dense and follow id order"
  end

  test "a publish waits for the stream's lock and gives up after lock_timeout_ms" do
    skip_unless_postgres
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      Sossego::Event.connection_pool.with_connection do
        Sossego::Event.with_stream_lock(STREAM_ID) do
          locked << true
          release.pop
        end
      end
    end
    locked.pop

    previous = Sossego::Event.lock_timeout_ms
    Sossego::Event.lock_timeout_ms = 50
    begin
      assert_raises(ActiveRecord::LockWaitTimeout) do
        Sossego::Event.publish(stream_id: STREAM_ID, event_name: "x", payload: "{}")
      end
      Sossego::Event.publish(stream_id: "#{STREAM_ID}:other", event_name: "x", payload: "{}")
    ensure
      Sossego::Event.lock_timeout_ms = previous
      release << true
      holder.join
      Sossego::Event.for_stream("#{STREAM_ID}:other").delete_all
    end

    assert_equal 0, Sossego::Event.for_stream(STREAM_ID).count
  end

  test "on SQLite a publish waits for a transaction that is writing, and lands after it" do
    skip_unless_sqlite

    written = Queue.new
    release = Queue.new
    holder = Thread.new do
      Sossego::Event.connection_pool.with_connection do
        Sossego::Event.transaction do
          # SQLite takes the write lock at the first statement, not at BEGIN
          Sossego::Event.publish(stream_id: STREAM_ID, event_name: "first", payload: {})
          written << true
          release.pop
        end
      end
    end
    written.pop

    waiter = Thread.new do
      Sossego::Event.connection_pool.with_connection do
        Sossego::Event.publish(stream_id: STREAM_ID, event_name: "second", payload: {})
      end
    end
    sleep 0.2
    assert waiter.alive?, "the second publish must wait for the first transaction"

    release << true
    holder.join
    waiter.join

    assert_equal [["first", 1], ["second", 2]], Sossego::Event.for_stream(STREAM_ID).order(:id).pluck(:event_name, :sseq)
  end
end
