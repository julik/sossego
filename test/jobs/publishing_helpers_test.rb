# frozen_string_literal: true

require "test_helper"

class Sossego::PublishingHelpersTest < ActiveJob::TestCase
  class Transient < StandardError; end

  class WorkingJob < ActiveJob::Base
    include Sossego::PublishingHelpers

    def perform(stream_id:)
      stream.publish_progress("Working...")
      stream.publish_field_prefill("expense[amount]" => "12.50")
    end
  end

  class FailingJob < ActiveJob::Base
    include Sossego::PublishingHelpers

    def perform(stream_id:, error: "ArgumentError")
      raise error.constantize, "nope"
    end
  end

  class FlakyJob < ActiveJob::Base
    include Sossego::PublishingHelpers

    sossego_retry_on Transient, attempts: 3, wait: 0

    def perform(stream_id:)
      raise Transient, "blip"
    end
  end

  class OtherArgumentJob < ActiveJob::Base
    include Sossego::PublishingHelpers

    self.sossego_stream_argument = :progress_stream

    def perform(progress_stream:)
      stream.publish_progress("Here")
    end
  end

  class OneOffJob < ActiveJob::Base
    include Sossego::PublishingHelpers

    self.sossego_close_stream = true
    sossego_retry_on Transient, attempts: 2, wait: 0

    def perform(stream_id:, outcome: :ok)
      stream.publish_progress("Working...")
      raise ArgumentError, "nope" if outcome == :fail
      raise Transient, "blip" if outcome == :flaky
      stream.publish_visit("/done")
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

  test "the events the concern publishes itself never mask the job's own error" do
    Sossego::Event.stub(:publish, ->(**) { raise "database is gone" }) do
      error = assert_raises(ArgumentError) { FailingJob.perform_now(stream_id: @stream.id) }
      assert_equal "nope", error.message
    end
  end

  test "the job's own publishes raise like any other call" do
    Sossego::Event.stub(:publish, ->(**) { raise "database is gone" }) do
      error = assert_raises(RuntimeError) { WorkingJob.perform_now(stream_id: @stream.id) }
      assert_equal "database is gone", error.message
    end
  end

  class OptionalStreamJob < ActiveJob::Base
    include Sossego::PublishingHelpers

    def perform(stream_id: nil)
      stream&.publish_progress("Only when someone watches")
    end
  end

  test "stream is nil without a stream id, and the concern publishes nothing" do
    assert_nothing_raised { OptionalStreamJob.perform_now }
    assert_raises(ArgumentError) { FailingJob.perform_now(stream_id: nil) }
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

  class TurboJob < ActiveJob::Base
    include Sossego::PublishingHelpers

    def perform(stream_id:, counter_id:)
      counter = Counter.find(counter_id)
      stream.publish_turbo_stream(:replace, target: counter, partial: "board/counter", locals: {counter: counter})
      stream.publish_turbo_stream(:remove, target: "spinner")
    end
  end

  class BrokenTurboJob < ActiveJob::Base
    include Sossego::PublishingHelpers

    def perform(stream_id:)
      stream.publish_turbo_stream(:append, target: "x", partial: "board/no_such_partial")
    end
  end

  test "publish_turbo_stream takes an action and renders it" do
    counter = Counter.create!(name: "Peace", value: 1)
    TurboJob.perform_now(stream_id: @stream.id, counter_id: counter.id)

    html = published.filter_map { |name, value| value if name == "turbo_stream" }
    assert_match(/\A<turbo-stream action="replace" target="counter_#{counter.id}"><template>.*Peace/m, html.first)
    assert_equal %(<turbo-stream action="remove" target="spinner"></turbo-stream>), html.last
  end

  test "a Turbo Stream that fails to render fails the job, which says so" do
    assert_raises(ActionView::MissingTemplate) { BrokenTurboJob.perform_now(stream_id: @stream.id) }

    assert_equal ["error_message", "progress_finished"], published.map(&:first)
  end

  class FailureOverrideJob < ActiveJob::Base
    include Sossego::PublishingHelpers

    def perform(stream_id:)
      raise ArgumentError, "the real problem"
    end

    def publish_failure(error)
      super
      raise "the visit could not be published"
    end
  end

  test "an override of publish_failure that raises does not replace the job's own error" do
    error = assert_raises(ArgumentError) { FailureOverrideJob.perform_now(stream_id: @stream.id) }

    assert_equal "the real problem", error.message
    assert_equal ["error_message", "progress_finished"], published.map(&:first)
  end

  test "a publish the concern swallows is reported to Rails.error, with the stream and the event" do
    report = assert_error_reported(RuntimeError) do
      Sossego::Event.stub(:publish, ->(**) { raise "database is gone" }) do
        assert_raises(ArgumentError) { FailingJob.perform_now(stream_id: @stream.id) }
      end
    end

    assert report.handled?
    assert_equal "sossego", report.source
    assert_equal @stream.id, report.context[:stream_id]
    assert_equal "Sossego::PublishingHelpersTest::FailingJob", report.context[:job]
    assert_includes %w[error_message progress_finished], report.context[:event_name]
  end

  test "a job that publishes fine reports nothing" do
    assert_no_error_reported { WorkingJob.perform_now(stream_id: @stream.id) }
  end
end
