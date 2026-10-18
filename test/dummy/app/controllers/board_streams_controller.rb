# frozen_string_literal: true

class BoardStreamsController < Sossego::StreamsController
  protected

  def sossego_stream
    Counter::STREAM
  end

  def sossego_body_options
    {ping_first: true, max_backlog: 20, poll_interval_s: 0.25}
  end
end
