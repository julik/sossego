require "test_helper"

class Sossego::SourceTest < ActiveSupport::TestCase
  setup { Sossego::Event.delete_all }

  test "fetch_after returns events for the stream and the current head, cursors as strings" do
    stream = Sossego::Stream.new("test:1:foo")
    published = Array.new(3) { |i| stream.publish("entity", {i: i}) }

    source = Sossego::Source.new(stream)
    events, head = source.fetch_after(nil)

    assert_equal 3, events.length
    assert_equal published.first.id.to_s, events[0].seq
    assert_equal 1, events[0].sseq
    assert_equal "entity", events[0].event_name
    assert_equal({"i" => 0}, events[0].pld)
    assert_equal published.last.id.to_s, head, "head is the stream's newest id at fetch time"
  end

  test "fetch_after honors the cursor" do
    stream = Sossego::Stream.new("test:1:foo")
    published = Array.new(5) { |i| stream.publish("entity", {i: i}) }

    source = Sossego::Source.new(stream)
    events, _head = source.fetch_after(published[2].id.to_s)

    assert_equal published.last(2).map { |ev| ev.id.to_s }, events.map(&:seq)
    assert_equal [4, 5], events.map(&:sseq)
  end

  test "fetch_after returns an empty array and the cursor as the head when no new events" do
    stream = Sossego::Stream.new("test:1:foo")
    stream.publish("entity", {})
    newest = stream.publish("entity", {})

    source = Sossego::Source.new(stream)
    events, head = source.fetch_after(newest.id.to_s)

    assert_empty events
    assert_equal newest.id.to_s, head
  end

  test "fetch_after with no cursor on a stream with no events reports the id counter as the head" do
    other = Sossego::Stream.new("other:1:foo").publish("entity", {})
    source = Sossego::Source.new(Sossego::Stream.new("empty:1:none"))

    events, head = source.fetch_after(nil)

    assert_empty events
    assert_kind_of String, head
    assert_operator head.to_i, :>=, other.id
  end

  test "EventTuple pld is JSON-parsed when payload is a JSON object" do
    stream = Sossego::Stream.new("test:1:foo")
    stream.publish("entity", {id: 7, in_inbox: true})

    events, _head = Sossego::Source.new(stream).fetch_after(nil)

    assert_equal({"id" => 7, "in_inbox" => true}, events.first.pld)
  end

  test "EventTuple pld falls through to the raw string when payload isn't JSON" do
    stream = Sossego::Stream.new("test:1:foo")
    Sossego::Event.publish(stream_id: stream.id, event_name: "content", payload: "raw text")

    events, _head = Sossego::Source.new(stream).fetch_after(nil)

    assert_equal "raw text", events.first.pld
  end

  test "stream_id exposes the underlying Stream#id" do
    stream = Sossego::Stream.new("acct:42:mail_messages")
    source = Sossego::Source.new(stream)

    assert_equal "acct:42:mail_messages", source.stream_id
  end

  test "a poll that finds no events runs one query and reports the cursor as the head" do
    stream = Sossego::Stream.new("test:1:foo")
    newest = Array.new(2) { stream.publish("entity", {}) }.last
    source = Sossego::Source.new(stream)

    events, head = assert_queries_count(1) { source.fetch_after(newest.id.to_s) }

    assert_empty events
    assert_equal newest.id.to_s, head
  end

  test "a partial batch runs one query and reports its last id as the head" do
    stream = Sossego::Stream.new("test:1:foo")
    published = Array.new(5) { stream.publish("entity", {}) }
    source = Sossego::Source.new(stream, batch_limit: 10)

    events, head = assert_queries_count(1) { source.fetch_after(published[2].id.to_s) }

    assert_equal [4, 5], events.map(&:sseq)
    assert_equal published.last.id.to_s, head
  end

  test "a full batch reads the true stream head with a second query" do
    stream = Sossego::Stream.new("test:1:foo")
    published = Array.new(10) { stream.publish("entity", {}) }
    source = Sossego::Source.new(stream, batch_limit: 3)

    events, head = assert_queries_count(2) { source.fetch_after(nil) }

    assert_equal [1, 2, 3], events.map(&:sseq)
    assert_equal published.last.id.to_s, head, "a full batch may not reach the head, so the head is read"
  end

  test "head is the stream's newest id as a string, and the id counter for a stream with no events" do
    stream = Sossego::Stream.new("test:1:foo")
    newest = Array.new(3) { stream.publish("entity", {}) }.last

    assert_equal newest.id.to_s, Sossego::Source.new(stream).head
    assert_equal Sossego::Event.id_counter_value.to_s, Sossego::Source.new(Sossego::Stream.new("empty:1:none")).head
  end

  test "backlog_start returns the cursor to start from as a string" do
    stream = Sossego::Stream.new("test:1:foo")
    published = Array.new(5) { stream.publish("entity", {}) }
    source = Sossego::Source.new(stream)

    assert_equal published[2].id.to_s, source.backlog_start(published.first.id.to_s, 2)
    assert_equal published[3].id.to_s, source.backlog_start(published[3].id.to_s, 2)
  end

  test "respects batch_limit" do
    stream = Sossego::Stream.new("test:1:foo")
    10.times { stream.publish("entity", {}) }

    source = Sossego::Source.new(stream, batch_limit: 3)
    events, _head = source.fetch_after(nil)

    assert_equal 3, events.length, "batch_limit caps the events returned per fetch"
  end
end
