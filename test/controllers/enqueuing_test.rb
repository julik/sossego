# frozen_string_literal: true

require "test_helper"

class Sossego::EnqueuingTest < ActiveSupport::TestCase
  class Host
    include Sossego::Enqueuing

    def logger = nil
  end

  setup do
    Sossego::Event.delete_all
    @stream = Sossego::Stream.random
  end

  def published
    Sossego::Event.for_stream(@stream.id).order(:id).map { |e| [e.event_name, e.value] }
  end

  test "acknowledges on the stream before handing off" do
    seen_in_block = nil

    assert Host.new.sossego_enqueue(@stream, ack: "Queued for analysis...") { seen_in_block = published }

    assert_equal [["progress", "Queued for analysis..."]], seen_in_block
    assert_equal [["progress", "Queued for analysis..."]], published
  end

  test "reports a hand-off that raised on the stream and returns false" do
    refute Host.new.sossego_enqueue(@stream) { raise IOError, "queue is down" }

    assert_equal ["progress", "error_message", "progress_finished"], published.map(&:first)
    assert_match(/IOError/, published[1].last)
  end

  test "can skip the acknowledgement" do
    Host.new.sossego_enqueue(@stream, ack: nil) {}

    assert_empty published
  end
end
