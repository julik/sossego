# frozen_string_literal: true

# A form that a background job fills in, reporting progress as it goes.
# The page makes a random stream and listens on it through the engine's
# signed endpoint; the form sends the stream URL back with the request that
# starts the job, and the server only publishes there when the signature
# holds.
class ProgressController < ApplicationController
  include Sossego::Enqueuing

  def new
    @stream = Sossego::Stream.random
  end

  # POST, from the form's JS, with the stream URL the page listens on
  def analyze
    stream = Sossego::Stream.verified_from_url(params[:stream_url])
    return head(:forbidden) unless stream

    enqueued = sossego_enqueue(stream, ack: "Queued for analysis...") do
      DemoAnalysisJob.perform_later(stream_id: stream.id, fail: params[:fail] == "1")
    end
    head(enqueued ? :accepted : :service_unavailable)
  end

  # The other shape: start the job, then redirect to a page that waits for
  # it. The job may publish before that page connects, so the signed
  # endpoint replays the stream from the start.
  def prepare
    stream = Sossego::Stream.random
    sossego_enqueue(stream, ack: "Queued...") do
      DemoPreparationJob.perform_later(stream_id: stream.id)
    end
    redirect_to preparing_progress_path(stream_id: stream.id, sig: stream.signature)
  end

  def preparing
    @stream = Sossego::Stream.verified(params[:stream_id], params[:sig])
    head(:forbidden) unless @stream
  end

  def prepared
  end
end
