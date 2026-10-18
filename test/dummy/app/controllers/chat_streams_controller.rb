# frozen_string_literal: true

# An open stream: anyone may read it. A real app checks who is asking in
# `show` and refuses with `refuse_stream("forbidden")`.
class ChatStreamsController < Sossego::StreamsController
  protected

  def sossego_stream
    ChatController::STREAM
  end

  def sossego_body_options
    {
      ping_first: true,
      max_backlog: 50,
      max_open_streams: 24,
      retry_ms: 1_000..3_000,
      poll_interval_s: 0.25,
      # Long messages go out gzipped; try pasting a few paragraphs.
      compress_above_bytes: 512
    }
  end
end
