# frozen_string_literal: true

module Sossego
  # For a controller that hands work to a {Reporting} job. Handing off is the
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
    # good and any wait after that belongs to the queue.
    #
    # @param stream [Sossego::Stream]
    # @param ack [String, nil] the first `progress` message; nil for none
    # @return [Boolean] true when the block ran without raising
    def sossego_enqueue(stream, ack: "Queued...")
      stream.publish("progress", ack) if ack
      yield
      true
    rescue => e
      logger&.error("[#{self.class.name}] could not enqueue: #{e.class.name}: #{e.message}")
      begin
        stream.publish("error_message", "Could not start the task (#{e.class.name.demodulize}). Please try again.")
        stream.publish("progress_finished")
      rescue => publish_error
        logger&.error("[#{self.class.name}] could not report the failed enqueue: #{publish_error.class}: #{publish_error.message}")
      end
      false
    end
  end
end
