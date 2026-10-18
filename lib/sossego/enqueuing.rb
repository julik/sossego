# frozen_string_literal: true

module Sossego
  # For a controller that hands work to a {PublishingHelpers} job. Handing off is the
  # one moment a progress display can start with nobody on the other end: if
  # enqueueing raises, the browser has already been told the task started
  # and would wait forever.
  #
  # @example
  #   class ReceiptsController < ApplicationController
  #     include Sossego::Enqueuing
  #
  #     def analyze
  #       stream = Sossego::Stream.verified_from_url(params[:stream_url])
  #       return head(:forbidden) unless stream
  #
  #       if sossego_enqueue(stream, ack: "Queued for analysis...") { ReceiptOcrJob.perform_later(stream_id: stream.id) }
  #         head :accepted
  #       else
  #         head :service_unavailable
  #       end
  #     end
  #   end
  module Enqueuing
    # Acknowledges on the stream, runs the block, and reports a failure on the
    # same stream if the hand-off does not survive. The acknowledgement
    # doubles as a liveness check: once the user sees it, the stream is known
    # good and any wait after that belongs to the queue. A failed hand-off
    # also goes to `Rails.error` ({Sossego.report_error}), as does a publish
    # that fails while reporting it.
    #
    # @param stream [Sossego::Stream]
    # @param ack [String, nil] the first `progress` message; nil for none
    # @return [Boolean] true when the block ran without raising
    def sossego_enqueue(stream, ack: "Queued...")
      stream.publish_progress(ack) if ack
      yield
      true
    rescue => e
      Sossego.report_error(e, message: "[#{self.class.name}] could not enqueue", logger: logger, stream_id: stream.id)
      begin
        stream.publish_error("Could not start the task (#{e.class.name.demodulize}). Please try again.")
        stream.publish_finished
      rescue => publish_error
        Sossego.report_error(publish_error, message: "[#{self.class.name}] could not report the failed enqueue", logger: logger, stream_id: stream.id)
      end
      false
    end
  end
end
