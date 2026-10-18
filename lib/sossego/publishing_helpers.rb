# frozen_string_literal: true

module Sossego
  # For an ActiveJob that drives a progress display in the browser over a
  # Sossego stream. The job takes the stream id as a keyword argument
  # (`stream_id:` unless {.sossego_stream_argument} says otherwise), and
  # publishes through {#stream} with the stream's helpers:
  # {Stream#publish_progress}, {Stream#publish_field_prefill} and the rest.
  #
  # Two things go wrong with a spinner driven by a background job, and to
  # the user they look identical - nothing happens, forever:
  #
  # 1. The job raises and never publishes a terminal event, so the browser
  #    keeps spinning on an already-dead task.
  # 2. The job never gets to run at all because it is queued behind
  #    unrelated work.
  #
  # This concern closes the first: every run ends with a terminal event
  # however it exits. Give the job a queue of its own for the second.
  #
  # - On success: `progress_finished`.
  # - On an error named with {.sossego_retry_on} that will be retried:
  #   `progress` saying it retries.
  # - On any other error, or the last attempt: `error_message` then
  #   `progress_finished` ({#publish_failure}), and the error is raised on.
  #
  # The events this concern publishes itself never raise: a failed one is
  # logged, so it never masks what the job was trying to report. The job's
  # own `stream.publish_*` calls raise like any other call.
  #
  # ## Closing the stream
  #
  # With `self.sossego_close_stream = true` the run also ends the stream for
  # good, after its last event: a stored `close` with reason `finished` or
  # `failed` (see {Stream#publish_close}). Every client reading the stream
  # stops, and none reconnects. Turn it on when the stream belongs to this
  # one task: a stream made with {Stream.random} for a task the page started
  # and then waits on, or one step of a wizard that moves on when it is done.
  # Leave it off when a page keeps one stream open for several tasks (a form
  # that can analyze a second upload), since a closed stream hears nothing
  # after the close.
  #
  # @example
  #   class ReceiptOcrJob < ApplicationJob
  #     include Sossego::PublishingHelpers
  #     queue_as :interactive
  #     sossego_retry_on Net::ReadTimeout, Errno::ECONNRESET, attempts: 3
  #
  #     def perform(receipt_id:, stream_id:)
  #       stream.publish_progress("Reading the receipt...")
  #       stream.publish_field_prefill("expense[amount]" => "12.50")
  #     end
  #   end
  #
  #   ReceiptOcrJob.perform_later(receipt_id: 1, stream_id: stream.id)
  module PublishingHelpers
    extend ActiveSupport::Concern

    included do
      class_attribute :sossego_stream_argument, default: :stream_id
      class_attribute :sossego_retried_errors, default: [].freeze
      class_attribute :sossego_max_attempts, default: 1
      class_attribute :sossego_close_stream, default: false

      around_perform do |job, block|
        block.call
        job.send(:quietly, "progress_finished") { job.stream&.publish_finished }
        job.close_sossego_stream("finished")
      rescue StandardError, ScriptError => e
        # ScriptError too (NotImplementedError and friends): it is not a
        # StandardError, so without it here such a failure sails past and
        # the spinner never stops.
        if job.sossego_will_retry?(e)
          job.send(:quietly, "progress") { job.stream&.publish_progress("#{e.class.name.demodulize} - retrying...") }
        else
          job.publish_failure(e)
          job.close_sossego_stream("failed")
        end
        raise
      end
    end

    class_methods do
      # `retry_on` for errors worth another go, telling the stream about the
      # retries and reporting the failure once the attempts run out.
      #
      # @param errors [Array<Class>]
      # @param attempts [Integer]
      # @param wait [Object] see `ActiveJob::Exceptions.retry_on`
      def sossego_retry_on(*errors, attempts: 3, wait: :polynomially_longer)
        self.sossego_retried_errors = (sossego_retried_errors + errors).freeze
        self.sossego_max_attempts = attempts
        retry_on(*errors, attempts: attempts, wait: wait) do |_job, error|
          raise error # the around_perform reported it; let the backend record the failure
        end
      end
    end

    # The stream this job reports to, read back off the job's arguments, so
    # it is there even when perform blew up before doing anything else. Nil
    # when the job was given none.
    #
    # @return [Sossego::Stream, nil]
    def stream
      id = arguments.grep(Hash).first&.[](sossego_stream_argument)
      Sossego::Stream.new(id) if id.present?
    end

    # @return [Boolean]
    def sossego_will_retry?(error)
      sossego_retried_errors.any? { |klass| error.is_a?(klass) } && executions < sossego_max_attempts
    end

    # Says what went wrong and stops the spinner. Always both events - an
    # error the user cannot see is the same to them as no error at all.
    # Override to add to it, calling `super`. Never raises.
    def publish_failure(error)
      logger&.error("[#{self.class.name}] #{error.class.name}: #{error.message}")
      quietly("error_message") { stream&.publish_error(sossego_failure_message(error)) }
      quietly("progress_finished") { stream&.publish_finished }
    end

    # Ends the stream for good when {.sossego_close_stream} is set. Never
    # raises.
    #
    # @param reason [String]
    def close_sossego_stream(reason)
      quietly("close") { stream&.publish_close(reason: reason) } if sossego_close_stream
    end

    # What the user reads when the job fails. Override to say less.
    #
    # @return [String]
    def sossego_failure_message(error)
      "#{error.class.name.demodulize}: #{error.message.to_s.truncate(200)}"
    end

    private

    def quietly(event_name)
      yield
    rescue => e
      logger&.error("[#{self.class.name}] could not publish #{event_name}: #{e.class}: #{e.message}")
      nil
    end
  end
end
