# frozen_string_literal: true

require "test_helper"

# The dummy app encrypts the payload column at rest, the way the generated
# initializer suggests. Every other test runs on encrypted rows too; this one
# checks that the column holds ciphertext and nothing else notices.
class Sossego::PayloadEncryptionTest < ActiveSupport::TestCase
  test "the column holds ciphertext, the model and the wire hold the payload" do
    stream = Sossego::Stream.new("enc:1:progress")
    event = stream.publish("entity", {subject: "Payroll"})

    raw = Sossego::Event.connection.select_value(
      Sossego::Event.sanitize_sql(["SELECT payload FROM sossego_events WHERE id = ?", event.id])
    )
    assert_no_match(/Payroll/, raw)
    assert_equal '{"subject":"Payroll"}', Sossego::Event.find(event.id).payload

    # What the streaming body sends: the row read back, in wire form
    stored = stream.events_after(nil).last
    tuple = Sossego::Source::EventTuple.new(stored.id.to_s, stored.sseq, stored.event_name, *stored.wire_pld_and_fmt)
    frame = Sossego.format_event_frame(tuple, head: event.id.to_s, sid: stream.id)
    assert_includes frame, '"pld":{"subject":"Payroll"}'
  end

  test "a row written before encryption is read as it was written" do
    Sossego::Event.connection.execute(<<~SQL)
      INSERT INTO sossego_events (stream_id, sseq, event_name, fmt, payload, created_at)
      VALUES ('enc:1:old', 1, 'inbox_changed', 'ejson', '{"plain":true}', CURRENT_TIMESTAMP)
    SQL

    assert_equal '{"plain":true}', Sossego::Event.for_stream("enc:1:old").last.payload
  end
end
