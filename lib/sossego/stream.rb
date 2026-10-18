# frozen_string_literal: true

require "securerandom"

module Sossego
  # Value object that identifies one stream in the events table. The id
  # is a string like:
  #
  # - `account:42:inbox` - everything an account's inbox page wants to hear
  # - `chat:99:tokens` - token chunks for chat 99
  # - `task:k7p2qd9z4m1x:progress` - one background task, see {.random}
  #
  # The convention is `<namespace>:<id>:<channel>` where the namespace
  # is the model name (singular, underscored - Rails default via
  # `ActiveModel::Name#singular`). Override per-class by defining
  # `sossego_namespace` on the class if the default doesn't fit.
  #
  # @example Build from a domain record
  #   Sossego::Stream.for(account, :inbox)
  #   # => #<Sossego::Stream "account:42:inbox">
  #
  # @example A stream for one background task, handed to the browser signed
  #   stream = Sossego::Stream.random
  #   sossego.signed_stream_path(stream_id: stream.id, sig: stream.signature)
  #
  # @example Publish application events, then end the stream for good
  #   stream = Sossego::Stream.new("task:7:progress")
  #   stream.publish("progress", {done: 3, of: 5})
  #   stream.publish("progress", {done: 4, of: 5}, after: 1)  # Sossego::Conflict unless sseq is 1
  #   stream.publish_close(reason: "finished")
  class Stream
    SIGNATURE_PURPOSE = :sossego_stream

    attr_reader :id

    def initialize(id)
      @id = id.to_s
      raise ArgumentError, "stream id must not be empty" if @id.empty?
    end

    # Build a stream identifier from a domain record + a channel name.
    #
    # @param record [#id, #class] anything ActiveRecord-shaped
    # @param channel [String, Symbol] the channel name within the record's
    #   namespace (e.g., :inbox, :tokens, :lifecycle)
    # @return [Sossego::Stream]
    def self.for(record, channel)
      namespace = if record.class.respond_to?(:sossego_namespace)
        record.class.sossego_namespace
      else
        record.class.model_name.singular
      end
      new("#{namespace}:#{record.id}:#{channel}")
    end

    # A stream nobody else will ever use, for one background task and the
    # page waiting on it. The random part is unguessable, but the browser
    # should still get it signed (see {#signature}).
    #
    # @param channel [String, Symbol]
    # @param namespace [String, Symbol]
    # @return [Sossego::Stream]
    def self.random(channel = :progress, namespace: :task)
      new("#{namespace}:#{SecureRandom.base36(12)}:#{channel}")
    end

    # The stream whose id the signature was made for, or nil when either is
    # missing or they do not match.
    #
    # @param id [String, nil]
    # @param signature [String, nil]
    # @return [Sossego::Stream, nil]
    def self.verified(id, signature)
      return if id.blank? || signature.blank?

      signed_id = Sossego.verifier.verified(signature, purpose: SIGNATURE_PURPOSE)
      new(id) if signed_id.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(signed_id, id.to_s)
    end

    # The stream named in a URL produced for {#signature}: a path or full
    # URL ending in `/<stream id>?sig=<signature>`. Lets a form send the
    # stream URL it is listening on back to the server, which then
    # publishes to the stream only when the signature holds.
    #
    # @param url [String, nil]
    # @return [Sossego::Stream, nil]
    def self.verified_from_url(url)
      return if url.blank?

      uri = URI.parse(url)
      id = Rack::Utils.unescape_path(uri.path.to_s.split("/").last.to_s)
      verified(id, Rack::Utils.parse_query(uri.query)["sig"])
    rescue URI::InvalidURIError
      nil
    end

    # A signature for this stream's id, for a URL that lets whoever holds
    # it read the stream: `Sossego::SignedStreamsController` serves the
    # stream to any request carrying it.
    #
    # @param expires_in [ActiveSupport::Duration, nil]
    # @return [String]
    def signature(expires_in: nil)
      Sossego.verifier.generate(@id, purpose: SIGNATURE_PURPOSE, expires_in: expires_in)
    end

    # Append an application event to this stream.
    #
    # @example Only if the stream's newest event is the one this caller saw
    #   stream.publish("progress", "Queued...", after: 3)
    #
    # @param event_name [String] not in {Sossego::RESERVED_EVENT_NAMES}
    # @example Text, a JSON value, bytes, and gzipped at rest
    #   stream.publish("progress", "Reading the receipt...")    # fmt "text"
    #   stream.publish("field_prefill", {"expense[amount]" => "1"})  # fmt "ejson"
    #   stream.publish("thumbnail", File.binread(path), fmt: :bytes)
    #   stream.publish("turbo_stream", big_html, fmt: "gz:text")
    #
    # @param payload [Object] see {Event.publish}
    # @param after [Integer, nil] see {Event.publish}
    # @param fmt [String, Symbol, nil] see {Event.publish}
    # @return [Sossego::Event]
    # @raise [Sossego::ReservedEventName] for a reserved name
    # @raise [Sossego::Conflict] when `after` is not the current `sseq`
    def publish(event_name, payload = nil, after: nil, fmt: nil)
      Event.publish(stream_id: @id, event_name: event_name, payload: payload, after: after, fmt: fmt)
    end

    # Append an application event once every open database transaction has
    # committed, so the event never announces a change a reader cannot see
    # yet. When a transaction rolls back, nothing is published. With no
    # transaction open it publishes at once.
    #
    # The name and `fmt` are checked now, so a mistake raises here. What
    # can only fail at the publish itself (the database, the lock wait) is
    # raised after the commit, out of the code that committed, unless
    # `on_error` is given: then the error goes to it and nothing raises.
    # That suits signals whose loss costs little, like "the inbox changed,
    # refetch": a lost one is replaced by the next.
    #
    # There is no `after:`: a conditional append checked after the commit
    # would check against a stream that has moved on.
    #
    # @example A signal that must never break the request that sent it
    #   Order.transaction do
    #     order.update!(state: "paid")
    #     Sossego::Stream.for(order.account, :orders).publish_after_commit("order_paid", {id: order.id},
    #       on_error: ->(error) { Rails.error.report(error, handled: true) })
    #   end
    #
    # @param event_name [String] not in {Sossego::RESERVED_EVENT_NAMES}
    # @param payload [Object] see {Event.publish}
    # @param fmt [String, Symbol, nil] see {Event.publish}
    # @param on_error [#call, nil] called with the error of a failed publish
    #   instead of raising it
    # @return [void]
    # @raise [Sossego::ReservedEventName] for a reserved name, at once
    # @raise [Sossego::UnknownEncoding] for an unregistered `fmt`, at once
    def publish_after_commit(event_name, payload = nil, fmt: nil, on_error: nil)
      unless Event.publishable_name?(event_name)
        raise Sossego::ReservedEventName, "#{event_name.inspect} is reserved by Sossego"
      end
      fmt = (fmt || Sossego.fmt_for(payload)).to_s
      Sossego.encoders.fetch(fmt) { raise Sossego::UnknownEncoding, "unknown sossego fmt: #{fmt.inspect}" }

      ActiveRecord.after_all_transactions_commit do
        publish(event_name, payload, fmt: fmt)
      rescue => e
        raise unless on_error
        on_error.call(e)
      end
      nil
    end

    # The transport API: append a `close` row, which ends the stream for
    # every client that reads up to it. The body writes it as a `close`
    # frame with its position and stops; the client does not reconnect.
    #
    # @param reason [String] machine-readable, handed to the client's `onClose`
    # @param after [Integer, nil] see {Event.publish}
    # @return [Sossego::Event]
    def publish_close(reason:, after: nil)
      Event.publish(stream_id: @id, event_name: SSE_EVENT_CLOSE, payload: {reason: reason}, after: after, transport: true)
    end

    # Events after the given cursor, in cursor order. A nil cursor means
    # none: every retained event.
    #
    # @param cursor [String, Integer, nil] an event id
    # @return [ActiveRecord::Relation<Sossego::Event>]
    def events_after(cursor)
      scope = Event.for_stream(@id)
      scope = scope.after_cursor(cursor) unless cursor.nil?
      scope.order(:id)
    end

    # The stream's head: the id of its newest retained event. A stream with
    # no retained events reports the id counter's current value, which is at
    # least every id issued so far and below every id still to come, so a
    # cursor taken from it misses nothing and never moves backwards.
    #
    # @return [Integer]
    def head
      Event.uncached do
        Event.for_stream(@id).maximum(:id) || Event.head_of_empty_stream(@id)
      end
    end

    # The cursor a connection should start from so that at most
    # `max_backlog` events after `cursor` are replayed: `cursor` itself when
    # no more than that many follow it, else the id of the event just before
    # the newest `max_backlog`. One query.
    #
    # @param cursor [String, Integer] an event id
    # @param max_backlog [Integer] at least 1
    # @return [String, Integer] the cursor to start from
    def backlog_start(cursor, max_backlog)
      Event.uncached do
        Event.for_stream(@id).after_cursor(cursor).order(id: :desc).offset(max_backlog).limit(1).pick(:id)
      end || cursor
    end

    def ==(other)
      other.is_a?(self.class) && other.id == @id
    end
    alias_method :eql?, :==

    def hash
      @id.hash
    end

    def to_s
      @id
    end

    def inspect
      "#<#{self.class.name} #{@id.inspect}>"
    end
  end
end
