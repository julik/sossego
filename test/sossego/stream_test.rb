require "test_helper"

class Sossego::StreamTest < ActiveSupport::TestCase
  setup { Sossego::Event.delete_all }

  # ----- direct construction -----

  test "Stream wraps an id string" do
    s = Sossego::Stream.new("account:42:mail_messages")
    assert_equal "account:42:mail_messages", s.id
    assert_equal "account:42:mail_messages", s.to_s
  end

  test "Stream rejects empty ids" do
    assert_raises(ArgumentError) { Sossego::Stream.new("") }
  end

  # ----- value semantics -----

  test "two Streams with the same id are equal" do
    a = Sossego::Stream.new("x:1:y")
    b = Sossego::Stream.new("x:1:y")
    assert_equal a, b
    assert_equal a.hash, b.hash
  end

  test "different-id Streams are not equal" do
    refute_equal Sossego::Stream.new("x:1:y"), Sossego::Stream.new("x:2:y")
  end

  # ----- .for(record, channel) — the domain-derivation convention -----

  # We use a fake record class rather than depending on a cora model.
  class FakeAccount
    attr_reader :id
    def initialize(id) = @id = id

    def self.model_name
      ActiveModel::Name.new(self, nil, "Account")
    end
  end

  test ".for derives namespace from class.model_name.singular" do
    s = Sossego::Stream.for(FakeAccount.new(42), :mail_messages)
    assert_equal "account:42:mail_messages", s.id
  end

  test ".for accepts string channels too" do
    s = Sossego::Stream.for(FakeAccount.new(7), "tokens")
    assert_equal "account:7:tokens", s.id
  end

  # Custom override via .sossego_namespace class method
  class CustomNamespacedThing
    attr_reader :id
    def initialize(id) = @id = id
    def self.sossego_namespace = "custom"
  end

  test ".for honors a class-level sossego_namespace override" do
    s = Sossego::Stream.for(CustomNamespacedThing.new(99), :events)
    assert_equal "custom:99:events", s.id
  end

  # ----- publish + events_after -----

  test "publish writes to the underlying Event table for this stream" do
    s = Sossego::Stream.new("test:1:foo")
    s.publish("entity", {a: 1})
    s.publish("entity", {a: 2})

    assert_equal 2, Sossego::Event.for_stream("test:1:foo").count
  end

  test "events_after returns events after the cursor in id order" do
    s = Sossego::Stream.new("test:1:foo")
    events = Array.new(3) { |i| s.publish("entity", {i: i}) }

    assert_equal events.drop(1).map(&:id), s.events_after(events.first.id.to_s).pluck(:id)
  end

  test "events_after with no cursor returns every retained event" do
    s = Sossego::Stream.new("test:1:foo")
    events = Array.new(2) { s.publish("entity", {}) }

    assert_equal events.map(&:id), s.events_after(nil).pluck(:id)
  end

  test "head returns the id of the newest event" do
    s = Sossego::Stream.new("test:1:foo")
    s.publish("entity", "{}")
    newest = s.publish("entity", "{}")
    Sossego::Stream.new("other:1:foo").publish("entity", "{}")

    assert_equal newest.id, s.head
  end

  test "head of a stream with no events is the id counter's value, at least every existing id" do
    other = Sossego::Stream.new("other:1:foo").publish("entity", "{}")
    s = Sossego::Stream.new("test:1:foo")

    head = s.head

    assert_equal Sossego::Event.id_counter_value, head
    assert_operator head, :>=, other.id
    assert_operator s.publish("entity", "{}").id, :>, head, "every later event sorts above that head"
  end

  test "head of a stream pruned empty does not move backwards" do
    s = Sossego::Stream.new("test:1:foo")
    s.publish("entity", "{}")
    before = s.head
    Sossego::Event.for_stream(s.id).delete_all

    assert_operator s.head, :>=, before
  end

  test "backlog_start keeps a cursor with at most max_backlog events after it" do
    s = Sossego::Stream.new("test:1:foo")
    events = Array.new(5) { s.publish("entity", {}) }

    assert_equal events[1].id.to_s, s.backlog_start(events[1].id.to_s, 3)
  end

  test "backlog_start moves a cursor further back to the event before the newest max_backlog" do
    s = Sossego::Stream.new("test:1:foo")
    events = Array.new(10) { s.publish("entity", {}) }
    Sossego::Stream.new("other:1:foo").publish("entity", {})

    start = assert_queries_count(1) { s.backlog_start(events.first.id.to_s, 3) }

    assert_equal events[6].id, start
    assert_equal events.last(3).map(&:id), s.events_after(start).pluck(:id)
  end

  test "publish raises ReservedEventName for a reserved name and stores nothing" do
    s = Sossego::Stream.new("test:1:foo")

    Sossego::RESERVED_EVENT_NAMES.each do |name|
      assert_raises(Sossego::ReservedEventName) { s.publish(name, {}) }
    end
    assert_equal 0, Sossego::Event.for_stream(s.id).count
  end

  test "publish passes after: through" do
    s = Sossego::Stream.new("test:1:foo")
    s.publish("progress", {done: 1})

    assert_equal 2, s.publish("progress", {done: 2}, after: 1).sseq
    assert_raises(Sossego::Conflict) { s.publish("progress", {done: 3}, after: 1) }
  end

  test "publish_close stores a close row with the reason as its payload, in sequence" do
    s = Sossego::Stream.new("test:1:foo")
    s.publish("progress", {done: 1})

    close = s.publish_close(reason: "finished")

    assert_equal "close", close.event_name
    assert_equal 2, close.sseq
    assert_equal({"reason" => "finished"}, JSON.parse(close.payload))
  end

  test "publish_close passes after: through" do
    s = Sossego::Stream.new("test:1:foo")

    assert_raises(Sossego::Conflict) { s.publish_close(reason: "finished", after: 1) }
    assert_equal 1, s.publish_close(reason: "finished", after: 0).sseq
  end

  test "publish on this Stream is isolated from publish on another" do
    a = Sossego::Stream.new("a:1:x")
    b = Sossego::Stream.new("b:1:x")
    a_event = a.publish("entity", "{}")
    b.publish("entity", "{}")
    b_event = b.publish("entity", "{}")

    assert_equal a_event.id, a.head
    assert_equal b_event.id, b.head
    assert_equal 2, b_event.sseq
  end

  test "publish_after_commit publishes inside a transactional test, as the host's tests will expect" do
    stream = Sossego::Stream.new("test:1:after_commit")
    stream.publish_after_commit("a")
    Sossego::Event.transaction { stream.publish_after_commit("b") }

    assert_equal %w[a b], Sossego::Event.for_stream(stream.id).order(:id).pluck(:event_name)
  end
end
