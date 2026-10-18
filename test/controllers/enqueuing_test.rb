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

  test "reports a failed hand-off to Rails.error" do
    report = assert_error_reported(IOError) do
      Host.new.sossego_enqueue(@stream) { raise IOError, "queue is down" }
    end

    assert report.handled?
    assert_equal "sossego", report.source
    assert_equal @stream.id, report.context[:stream_id]
  end

  test "reports a publish that fails while reporting the failed hand-off" do
    calls = 0
    flaky_publish = ->(**kwargs) {
      calls += 1
      raise "database is gone" if calls > 1   # the ack goes through, the error report doesn't
      Sossego::Event.new(kwargs.except(:transport, :after, :fmt).merge(sseq: 1))
    }

    reports = capture_error_reports do
      Sossego::Event.stub(:publish, flaky_publish) do
        refute Host.new.sossego_enqueue(@stream) { raise IOError, "queue is down" }
      end
    end

    assert_equal [IOError, RuntimeError], reports.map { |r| r.error.class }
  end
end
