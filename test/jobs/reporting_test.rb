# frozen_string_literal: true

require "test_helper"

class Sossego::ReportingTest < ActiveJob::TestCase
  class Transient < StandardError; end

  class WorkingJob < ActiveJob::Base
    include Sossego::Reporting

    def perform(stream_id:)
      publish_progress("Working...")
      publish_field_prefill("expense[amount]" => "12.50")
    end
  end

  class FailingJob < ActiveJob::Base
    include Sossego::Reporting

    def perform(stream_id:, error: "ArgumentError")
      raise error.constantize, "nope"
    end
  end

  class FlakyJob < ActiveJob::Base
    include Sossego::Reporting

    sossego_retry_on Transient, attempts: 3, wait: 0

    def perform(stream_id:)
      raise Transient, "blip"
    end
  end

  class OtherArgumentJob < ActiveJob::Base
    include Sossego::Reporting

    self.sossego_stream_argument = :progress_stream

    def perform(progress_stream:)
      publish_progress("Here")
    end
  end

  class OneOffJob < ActiveJob::Base
    include Sossego::Reporting

    self.sossego_close_stream = true
    sossego_retry_on Transient, attempts: 2, wait: 0

    def perform(stream_id:, outcome: :ok)
      publish_progress("Working...")
      raise ArgumentError, "nope" if outcome == :fail
      raise Transient, "blip" if outcome == :flaky
      publish_visit("/done")
    end
  end

  setup do
    Sossego::Event.delete_all
    @stream = Sossego::Stream.random
  end

  def published
    Sossego::Event.for_stream(@stream.id).order(:id).map { |e| [e.event_name, e.value] }
  end

  test "ends a successful run with progress_finished" do
    WorkingJob.perform_now(stream_id: @stream.id)

    assert_equal [
      ["progress", "Working..."],
      ["field_prefill", {"expense[amount]" => "12.50"}],
      ["progress_finished", nil]
    ], published
  end

  test "publishes an error and a terminal event when the job blows up, and raises on" do
    assert_raises(ArgumentError) { FailingJob.perform_now(stream_id: @stream.id) }

    assert_equal [["error_message", "ArgumentError: nope"], ["progress_finished", nil]], published
  end

  test "reports failures that are not StandardError" do
    assert_raises(NotImplementedError) { FailingJob.perform_now(stream_id: @stream.id, error: "NotImplementedError") }

    assert_equal ["error_message", "progress_finished"], published.map(&:first)
  end

  test "says it retries a transient error, and reports once the attempts run out" do
    perform_enqueued_jobs do
      assert_raises(Transient) { FlakyJob.perform_later(stream_id: @stream.id) }
    end

    assert_equal [
      ["progress", "Transient - retrying..."],
      ["progress", "Transient - retrying..."],
      ["error_message", "Transient: blip"],
      ["progress_finished", nil]
    ], published
  end

  test "reads the stream from another argument when told to" do
    OtherArgumentJob.perform_now(progress_stream: @stream.id)

    assert_equal ["progress", "progress_finished"], published.map(&:first)
  end

  test "a publish that fails does not mask the job's own outcome" do
    Sossego::Event.stub(:publish, ->(**) { raise "database is gone" }) do
      assert_nothing_raised { WorkingJob.perform_now(stream_id: @stream.id) }
    end
  end

  test "does nothing without a stream" do
    assert_nothing_raised { WorkingJob.perform_now(stream_id: nil) }
    assert_equal 0, Sossego::Event.count
  end

  test "does not close the stream unless told to" do
    WorkingJob.perform_now(stream_id: @stream.id)

    refute_includes published.map(&:first), "close"
  end

  test "a job told to close ends the stream after its last event when it succeeds" do
    OneOffJob.perform_now(stream_id: @stream.id)

    assert_equal [
      ["progress", "Working..."],
      ["visit", "/done"],
      ["progress_finished", nil],
      ["close", {"reason" => "finished"}]
    ], published
  end

  test "a job told to close ends the stream after reporting a failure" do
    assert_raises(ArgumentError) { OneOffJob.perform_now(stream_id: @stream.id, outcome: :fail) }

    assert_equal ["progress", "error_message", "progress_finished", "close"], published.map(&:first)
    assert_equal({"reason" => "failed"}, published.last.last)
  end

  test "a job told to close keeps the stream open across retries, and closes once they run out" do
    perform_enqueued_jobs do
      assert_raises(Transient) { OneOffJob.perform_later(stream_id: @stream.id, outcome: :flaky) }
    end

    names = published.map(&:first)
    assert_equal 1, names.count("close")
    assert_equal "close", names.last
    assert_equal ["progress", "progress", "progress", "error_message", "progress_finished", "close"], names
  end
end
