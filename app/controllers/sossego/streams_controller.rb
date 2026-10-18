# frozen_string_literal: true

module Sossego
  # Base controller for SSE streaming endpoints. Inherit from it and
  # override {#sossego_stream} to return a {Sossego::Stream} for the
  # current request.
  #
  # Plain Rack body, **no `ActionController::Live`**. The streaming body
  # is just a Ruby object responding to `#each` - Rails dispatches
  # normally, Rack iterates the body and writes each yielded chunk to
  # the socket. The streaming headers we set defeat the middleware that
  # would otherwise buffer.
  #
  # The `show` action handles everything: streaming headers, the IO-bound
  # mark for Puma, body wiring, Last-Event-ID extraction. A subclass that
  # needs to do extra work (authorize, log) overrides `show` and calls
  # `super`.
  #
  # @example Minimal subclass - just provide the stream
  #   class InboxStreamsController < Sossego::StreamsController
  #     protected
  #
  #     def sossego_stream
  #       Sossego::Stream.for(Current.account, :inbox)
  #     end
  #   end
  #
  # @example Subclass that bounds the stream and refuses in-band
  #   class InboxStreamsController < Sossego::StreamsController
  #     def show
  #       return refuse_stream("unauthenticated") unless current_user
  #       @account = current_user.accounts.find_by(id: params[:account])
  #       return refuse_stream("forbidden") unless @account
  #
  #       super
  #     end
  #
  #     protected
  #
  #     def sossego_stream
  #       Sossego::Stream.for(@account, :inbox)
  #     end
  #
  #     def sossego_body_options
  #       {max_open_streams: 16, ping_first: true, max_backlog: 100}
  #     end
  #   end
  #
  # ## The stream never writes the session
  #
  # Reading `current_user` loads the session, and Rack would write the
  # session cookie back on every reconnect (about every 33 seconds per open
  # tab) from this request's copy - over a newer session a concurrent
  # request (sign-out, account switch, flash) had just written. Every
  # response from this controller, served or refused, skips the session
  # write. A subclass that really wants it overrides {#skip_session_write?}.
  #
  # ## Inheritance
  #
  # Inherits from `ActionController::Base`, not the host's
  # `ApplicationController`: a stream connect is not a page view, and
  # filters that set cookies, track visits or switch accounts do not belong
  # on it. A subclass brings its own answer to who is asking and what they
  # may read.
  class StreamsController < ActionController::Base
    def show
      stream = sossego_stream
      return refuse_stream("forbidden") unless stream

      set_streaming_headers
      # Lets Puma count this thread against `max_io_threads` instead of
      # the request threads. A no-op unless the Puma config sets it.
      request.env["puma.mark_as_io_bound"]&.call

      self.response_body = Sossego::StreamingBody.new(
        source: Sossego::Source.new(stream),
        last_id: last_event_id,
        logger: logger,
        **sossego_body_options
      )
    end

    # Resume cursor - read from the standard SSE request header first
    # (sent by the browser's native EventSource auto-reconnect), and
    # fall back to the `last_event_id` query param. The query-param
    # path is what the client uses when it reopens a connection
    # manually after the browser gave up (readyState=CLOSED), since
    # request headers can't be set on a new `EventSource`.
    #
    # A value that is not a valid cursor ({Sossego::Event.cursor_valid?})
    # counts as no cursor.
    #
    # @return [String, nil]
    def last_event_id
      cursor = request.headers["Last-Event-ID"].presence || params[:last_event_id].presence
      cursor if cursor && Sossego::Event.cursor_valid?(cursor.to_s)
    end

    protected

    # Override in subclass. Return a {Sossego::Stream} for the current
    # request. Return `nil` to refuse the connection in-band, with reason
    # `forbidden` (see {#refuse_stream}).
    def sossego_stream
      raise NotImplementedError, "#{self.class.name} must override #sossego_stream"
    end

    # Override in subclass to set {StreamingBody} options for this
    # request: `max_open_streams`, `open_streams_gauge`, `on_over_budget`,
    # `ping_first`, `max_backlog`, `poll_interval_s`, `retry_ms`,
    # `compress_above_bytes`.
    #
    # @return [Hash] keyword arguments for {StreamingBody#initialize}
    def sossego_body_options
      {}
    end

    # Refuse the connection in a way the client can read: HTTP 200, the
    # streaming headers, and one `close` frame naming the reason as the
    # whole body. The frame has no `id:` and no position. An EventSource
    # sees nothing of a 401, a 403 or a redirect but a failed connection,
    # which the client would keep reopening.
    #
    # @param reason [String] e.g. "unauthenticated", "forbidden"
    # @return [void]
    def refuse_stream(reason)
      set_streaming_headers
      self.response_body = [Sossego.format_close_frame(reason: reason)]
    end

    # @return [Boolean]
    def skip_session_write?
      true
    end

    private

    def set_streaming_headers
      request.session_options[:skip] = true if skip_session_write?
      response.headers.merge!(Sossego::STREAMING_HEADERS)
      response.headers["Last-Modified"] = Time.now.httpdate
    end
  end
end
