require "test_helper"

class Sossego::PruneJobTest < ActiveJob::TestCase
  setup { Sossego::Event.delete_all }

  test "deletes every event past retention, including a stream's newest" do
    a_old = Sossego::Event.publish(stream_id: "s:a", event_name: "entity", payload: "{}")
    a_newest = Sossego::Event.publish(stream_id: "s:a", event_name: "entity", payload: "{}")
    a_old.update_columns(created_at: 49.hours.ago)
    a_newest.update_columns(created_at: 49.hours.ago)
    b_fresh = Sossego::Event.publish(stream_id: "s:b", event_name: "entity", payload: "{}")

    Sossego::PruneJob.perform_now

    refute Sossego::Event.exists?(a_old.id)
    refute Sossego::Event.exists?(a_newest.id), "the newest row of a stream is not kept back"
    assert Sossego::Event.exists?(b_fresh.id), "fresh event untouched"
  end

  test "the default retention window is 24 hours: an event 25 hours old goes and one 23 hours old stays" do
    past_retention = Sossego::Event.publish(stream_id: "s:1", event_name: "entity", payload: "{}")
    within_retention = Sossego::Event.publish(stream_id: "s:1", event_name: "entity", payload: "{}")
    past_retention.update_columns(created_at: 25.hours.ago)
    within_retention.update_columns(created_at: 23.hours.ago)

    Sossego::PruneJob.perform_now

    refute Sossego::Event.exists?(past_retention.id)
    assert Sossego::Event.exists?(within_retention.id)
  end

  test "a stream pruned empty resumes: the next event sorts after the old cursor" do
    old_newest = Array.new(3) { Sossego::Event.publish(stream_id: "s:quiet", event_name: "entity", payload: "{}") }.last
    Sossego::Event.for_stream("s:quiet").update_all(created_at: 49.hours.ago)

    Sossego::PruneJob.perform_now
    assert_equal 0, Sossego::Event.for_stream("s:quiet").count

    next_event = Sossego::Event.publish(stream_id: "s:quiet", event_name: "entity", payload: "{}")
    assert_equal 1, next_event.sseq
    assert_equal [next_event.id], Sossego::Stream.new("s:quiet").events_after(old_newest.id.to_s).pluck(:id)
  end

  test "no-op when nothing is past the retention window" do
    Sossego::Event.publish(stream_id: "s:1", event_name: "entity", payload: "{}")
    Sossego::Event.publish(stream_id: "s:1", event_name: "entity", payload: "{}")

    assert_no_difference -> { Sossego::Event.count } do
      Sossego::PruneJob.perform_now
    end
  end

  test "follows Sossego.retention" do
    previous = Sossego.retention
    Sossego.retention = 12.hours
    event = Sossego::Event.publish(stream_id: "s:1", event_name: "entity", payload: {})
    event.update_columns(created_at: 13.hours.ago)

    Sossego::PruneJob.perform_now

    refute Sossego::Event.exists?(event.id)
  ensure
    Sossego.retention = previous
  end

  test "takes the retention as an argument too" do
    event = Sossego::Event.publish(stream_id: "s:1", event_name: "entity", payload: {})
    event.update_columns(created_at: 2.hours.ago)

    Sossego::PruneJob.perform_now(older_than: 1.hour)

    refute Sossego::Event.exists?(event.id)
  end
end
