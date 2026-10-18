# frozen_string_literal: true

module Sossego
  # Serves any stream to a request that carries the stream id and its
  # signature: `GET /sossego/streams/:stream_id?sig=...` (mounted where the
  # host mounts the engine). The signed URL is the permission, so it suits
  # streams made for one page, typically {Stream.random} for a background
  # task.
  #
  # A connection without a cursor replays the stream from its first
  # retained event. That is what a page rendered after the task was
  # enqueued needs: the task may have published before the browser
  # connected.
  #
  # @example In a view
  #   <div data-controller="sossego" data-sossego-url-value="<%= sossego_signed_stream_path(@stream) %>"></div>
  class SignedStreamsController < StreamsController
    protected

    def sossego_stream
      Sossego::Stream.verified(params[:stream_id], params[:sig])
    end
  end
end
