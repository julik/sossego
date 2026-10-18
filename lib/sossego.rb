# frozen_string_literal: true

require "json"
require "base64"
require "zlib"
require "stringio"
require "active_support"
require "active_support/core_ext"
require "rails/engine"
require "action_view"

require_relative "sossego/version"

# Sossego - Server-Sent Events made peaceful.
#
# Named after Tim Maia's song "Sossego" (1977)
#   "Sossego, eu preciso de sossego
#    Quero sossego pra minha alma"
#
# Events are rows in an append-only table. A plain Rack body polls the table
# for one stream and writes SSE frames; the browser resumes by cursor through
# `Last-Event-ID`. The full specification is WIRE_FORMAT.md at the root of the
# gem. In short:
#
# The SSE `event:` field only ever carries a name the substrate owns:
# `sossego` (one application event), `ping` (liveness) or `close` (the
# stream is over, do not reconnect). Application event names travel inside
# the envelope as `evt`, never in the SSE slot (see {RESERVED_EVENT_NAMES}).
#
# The `data:` text of every frame is one JSON object, the envelope,
# pretty-printed across `data:` lines (the browser joins them with `\n`):
#
#   event: sossego
#   id: 119
#   data: {
#   data:   "fmt": "ejson",
#   data:   "evt": "inbox_changed",
#   data:   "seq": "119",
#   data:   "sseq": 57,
#   data:   "head": "119",
#   data:   "sid": "account:42:inbox",
#   data:   "pld": {}
#   data: }
#
# - `fmt` says how to turn `pld` into a value ({.encoders}, {.decoders}).
# - `evt` is the application's event name, or the SSE name on a transport
#   frame (`ping`, `close`).
# - `seq` is the cursor: the row's id, as a string, equal to the `id:`
#   line. Ruby never parses it; clients compare cursors only by length,
#   then lexicographically.
# - `sseq` is the stream sequence, an integer: dense per stream among
#   retained rows, starting at 1. For gap detection, never a cursor.
# - `head` is the stream's newest cursor, on positioned frames and pings.
# - `pld` is the payload: whatever was published; `{head, time}` on a ping;
#   `{reason}` on a close.
module Sossego
  # Raised for an envelope whose `fmt` is missing or not registered in
  # {encoders} / {decoders}.
  class UnknownEncoding < ArgumentError; end

  # Raised when an application tries to publish under a name in
  # {RESERVED_EVENT_NAMES}.
  class ReservedEventName < ArgumentError; end

  # Raised by a publish given `after:` when the stream's current `sseq` is
  # not that value. Nothing is written; there is no retry.
  class Conflict < StandardError; end

  # SSE name of a frame carrying one application event.
  SSE_EVENT_SOSSEGO = "sossego"
  # SSE name of a liveness frame. Never stored.
  SSE_EVENT_PING = "ping"
  # SSE name of the frame that ends a stream for good.
  SSE_EVENT_CLOSE = "close"

  # Names an application may not publish under. The first three are the
  # substrate's SSE names; the last three are what the browser's
  # EventSource fires by itself. Only the transport API
  # ({Stream#publish_close}) stores a row under one, and only `close`.
  RESERVED_EVENT_NAMES = %w[sossego ping close open error message].freeze

  # A JSON value, embedded in the envelope as-is. What a non-String
  # payload is published as.
  FMT_EJSON = "ejson"
  # A String, embedded as a JSON string. What a String payload is published as.
  FMT_TEXT = "text"
  # Bytes, as base64. Only when asked for with `fmt: "bytes"`.
  FMT_BYTES = "bytes"
  # Prefix of a gzipped variant of the formats above: `pld` is base64 of the
  # gzipped JSON text, UTF-8 text or bytes.
  GZIP_PREFIX = "gz:"

  # The `fmt` of frames the substrate writes itself (pings, closes).
  DEFAULT_FMT = FMT_EJSON

  # Headers that any SSE response needs to survive a proxy stack.
  # Each entry is load-bearing:
  #
  # - `Content-Type` - required by EventSource
  # - `Cache-Control` - keeps caches and proxies from holding the response
  # - `Connection` - keeps TCP open
  # - `Content-Encoding: identity` - blocks Rack::Deflater from buffering
  #   the entire response to compress it (would break streaming)
  # - `X-Accel-Buffering: no` - disables nginx and GCP HTTPS load balancer
  #   upstream buffering (without this, edges buffer ~32KB before flushing)
  #
  # Plus `Last-Modified: now`, set per request by {StreamsController}, to
  # defeat Rack::ETag's "I'll buffer to compute the etag" behavior.
  STREAMING_HEADERS = {
    "Content-Type" => "text/event-stream",
    "Cache-Control" => "no-cache, no-store, must-revalidate",
    "Connection" => "keep-alive",
    "Content-Encoding" => "identity",
    "X-Accel-Buffering" => "no"
  }.freeze

  class << self
    # How long events are kept. {PruneJob} deletes anything older.
    # @return [ActiveSupport::Duration]
    attr_accessor :retention

    # Passed to `connects_to` on {ApplicationRecord} when set, so the events
    # table can live in its own database. Set it in an initializer, before
    # the models load.
    #
    # @example
    #   Sossego.connects_to = {database: {writing: :sossego, reading: :sossego_replica}}
    # @return [Hash, nil]
    attr_accessor :connects_to

    # Wraps every poll a stream makes. Called with the poll, a callable that
    # runs the queries and returns their result; return what it returns.
    # Unset, the poll runs on whatever connection `Sossego::Event` has. Use
    # it to poll on another connection, so a stream - which stays open for
    # half a minute - never holds a write-capable one. The initializer the
    # install generator writes has recipes.
    #
    # @example Poll on the app's reading role
    #   Sossego.around_poll = ->(poll) { Sossego.connection_class.connected_to(role: :reading) { poll.call } }
    # @return [#call, nil]
    attr_accessor :around_poll

    # Renders the templates of Turbo Streams ({TurboStream.render}): returns
    # something that responds to `render`, like a controller class. Defaults to
    # `ApplicationController`, as turbo-rails' broadcasts do.
    #
    # @example
    #   Sossego.turbo_stream_renderer = -> { Admin::BaseController }
    # @return [#call]
    attr_writer :turbo_stream_renderer

    def turbo_stream_renderer
      @turbo_stream_renderer ||= -> { defined?(::ApplicationController) ? ::ApplicationController : ActionController::Base }
    end

    # Signs and verifies stream ids handed to the browser (see
    # {Stream#signature}). Defaults to the application's message verifier
    # named "sossego_streams".
    # @return [ActiveSupport::MessageVerifier]
    attr_writer :verifier

    def verifier
      @verifier ||= Rails.application.message_verifier("sossego_streams")
    end
  end
  self.retention = 24.hours

  # The class whose connection `Sossego::Event` uses, and so the one to call
  # `connected_to` on: `Sossego::ApplicationRecord` with {.connects_to} set,
  # `ActiveRecord::Base` without.
  #
  # @return [Class]
  def self.connection_class
    connects_to ? Sossego::ApplicationRecord : ActiveRecord::Base
  end

  # Polls on a read-only copy of the SQLite connection: the same database
  # file, opened with SQLITE_OPEN_READONLY, in a pool of its own. Nothing the
  # polling does can then take the write lock. The pool is set up at the
  # first poll, so this can be called from an initializer.
  #
  # A connection of its own cannot see what a test's transaction wrote, so
  # don't call this in the test environment.
  #
  # @param role [Symbol] the role the copy is registered under
  # @return [void]
  def self.poll_on_readonly_sqlite_connection!(role: :sossego_readonly)
    lock = Mutex.new
    established = false
    self.around_poll = ->(poll) do
      lock.synchronize do
        next if established

        writing = Sossego::Event.connection_db_config
        unless writing.adapter.to_s.include?("sqlite")
          raise ArgumentError, "a read-only copy of the connection is for SQLite; poll on a reading role instead (see Sossego.around_poll)"
        end
        readonly = ActiveRecord::DatabaseConfigurations::HashConfig.new(writing.env_name, "#{writing.name}_#{role}", writing.configuration_hash.merge(readonly: true))
        ActiveRecord::Base.connection_handler.establish_connection(readonly, owner_name: connection_class, role: role)
        established = true
      end
      connection_class.connected_to(role: role) { poll.call }
    end
    nil
  end

  # Encoders by `fmt`. Each takes the application's value and returns what
  # goes into the envelope's `pld`. {Event.publish} runs the value through
  # one and stores the result, so a stored row is already in wire form.
  #
  # @example Register another encoding (and its decoder, and the client's)
  #   Sossego.encoders["msgpack"] = ->(value) { Base64.strict_encode64(MessagePack.pack(value)) }
  #
  # @return [Hash{String => #call}]
  def self.encoders
    @encoders ||= {
      FMT_EJSON => ->(value) { value },
      FMT_TEXT => ->(value) { utf8_text(value) },
      FMT_BYTES => ->(value) { Base64.strict_encode64(value.to_s.b) },
      "#{GZIP_PREFIX}#{FMT_EJSON}" => ->(value) { Base64.strict_encode64(gzip(JSON.generate(value.as_json))) },
      "#{GZIP_PREFIX}#{FMT_TEXT}" => ->(value) { Base64.strict_encode64(gzip(utf8_text(value))) },
      "#{GZIP_PREFIX}#{FMT_BYTES}" => ->(value) { Base64.strict_encode64(gzip(value.to_s.b)) }
    }
  end

  # Decoders by `fmt`. Each takes `pld` as parsed from the envelope and
  # returns the application's value: what was published, with Hash keys as
  # strings, and bytes as a binary String.
  #
  # @return [Hash{String => #call}]
  def self.decoders
    @decoders ||= {
      FMT_EJSON => ->(pld) { pld },
      FMT_TEXT => ->(pld) { pld },
      FMT_BYTES => ->(pld) { Base64.strict_decode64(pld) },
      "#{GZIP_PREFIX}#{FMT_EJSON}" => ->(pld) { JSON.parse(gunzip(pld)) },
      "#{GZIP_PREFIX}#{FMT_TEXT}" => ->(pld) { gunzip(pld).force_encoding(::Encoding::UTF_8) },
      "#{GZIP_PREFIX}#{FMT_BYTES}" => ->(pld) { gunzip(pld) }
    }
  end

  # The `fmt` a payload is published as when none is given: `text` for a
  # String, `ejson` for anything else. Bytes are never guessed at, since a
  # String read with `File.binread` is binary-encoded whatever it holds.
  #
  # @return [String]
  def self.fmt_for(value)
    value.is_a?(String) ? FMT_TEXT : FMT_EJSON
  end

  # Decode the `data:` text of a frame (its lines joined with `\n`, as the
  # browser does): parse the envelope, then run `pld` through the decoder
  # its `fmt` names.
  #
  # @param data_text [String]
  # @return [Hash{String => Object}] the envelope, with `pld` decoded
  # @raise [UnknownEncoding] when `fmt` is missing or not registered
  # @raise [JSON::ParserError] when the text is not JSON
  def self.decode_frame(data_text)
    envelope = JSON.parse(data_text)
    raise UnknownEncoding, "sossego frame is not a JSON object" unless envelope.is_a?(Hash)

    decoder = decoders.fetch(envelope["fmt"]) { raise UnknownEncoding, "unknown sossego fmt: #{envelope["fmt"].inspect}" }
    envelope.merge("pld" => decoder.call(envelope["pld"]))
  end

  # Build an envelope: the keys in wire order, the positional keys left
  # out when nil, and `pld` run through the encoder `fmt` names.
  #
  # @example A frame with no position
  #   Sossego.envelope(evt: "close", pld: {reason: "flag_off"})
  #   # => {fmt: "ejson", evt: "close", pld: {reason: "flag_off"}}
  #
  # @param encoded [Boolean] `pld` is in wire form already (a stored row),
  #   so no encoder runs
  # @return [Hash] envelope ready for {format_frame}
  # @raise [UnknownEncoding] when `fmt` is not registered
  def self.envelope(evt:, pld:, fmt: DEFAULT_FMT, seq: nil, sseq: nil, head: nil, sid: nil, encoded: false)
    unless encoded
      encoder = encoders.fetch(fmt) { raise UnknownEncoding, "unknown sossego fmt: #{fmt.inspect}" }
      pld = encoder.call(pld)
    end
    {fmt: fmt, evt: evt, seq: seq&.to_s, sseq: sseq&.to_i, head: head&.to_s, sid: sid, pld: pld}
      .reject { |key, value| value.nil? && key != :pld }
  end

  # Format a complete SSE frame: the `event:` line, the `id:` line when
  # given, the envelope pretty-printed as one `data:` line per line of
  # JSON, then the blank line.
  #
  # @param sse_event [String] one of {SSE_EVENT_SOSSEGO}, {SSE_EVENT_PING},
  #   {SSE_EVENT_CLOSE}
  # @param envelope [Hash] from {envelope}
  # @param id [#to_s, nil] SSE `id:` field, equal to the envelope's `seq`.
  #   Nil leaves the line out, so the browser keeps its last event id.
  # @return [String] complete SSE frame
  def self.format_frame(sse_event:, envelope:, id: nil)
    lines = ["event: #{sse_event}"]
    lines << "id: #{id}" unless id.nil?
    JSON.pretty_generate(envelope).each_line { |line| lines << "data: #{line.chomp}" }
    lines << "" << ""
    lines.join("\n")
  end

  # Format the `sossego` frame for one stored application event.
  #
  # @param event [#seq, #sseq, #event_name, #pld] a stored row, e.g.
  #   {Source::EventTuple}, its `pld` in the wire form its `fmt` names. An
  #   event that has no `fmt`, or a nil one, is `ejson`.
  # @param head [String] the stream's head cursor when the frame is written
  # @param sid [String] the stream id
  # @return [String] complete SSE frame
  def self.format_event_frame(event, head:, sid:)
    seq = event.seq.to_s
    format_frame(
      sse_event: SSE_EVENT_SOSSEGO,
      id: seq,
      envelope: envelope(fmt: fmt_of(event), evt: event.event_name, seq: seq, sseq: event.sseq, head: head, sid: sid, pld: event.pld, encoded: true)
    )
  end

  # Format a ping. Used by {StreamingBody} as its heartbeat: visible to the
  # JS client, so it can reset its stall timer, while still keeping TCP
  # alive through proxies. Never stored, no `id:`.
  #
  # @param head [String] the stream's current head cursor
  # @param time [Time] timestamp; defaults to now
  # @return [String] complete SSE frame
  def self.format_ping_frame(head:, time: Time.now)
    head = head.to_s
    format_frame(
      sse_event: SSE_EVENT_PING,
      envelope: envelope(evt: SSE_EVENT_PING, head: head, pld: {head: head, time: time.utc.iso8601})
    )
  end

  # Format a `close` frame: the stream is over for this client, which must
  # not reconnect.
  #
  # Without `seq` it is a refusal: no `id:` line and no position. A refusal
  # goes out as HTTP 200 with this frame as the whole body, because an
  # EventSource cannot read the status or body of a failed response: an
  # in-band reason is the only one the client can act on.
  #
  # With `seq` it is a stored close ({Stream#publish_close}), written with
  # its position like any other row.
  #
  # @param reason [String] machine-readable reason, read by the client
  # @return [String] complete SSE frame
  def self.format_close_frame(reason:, seq: nil, sseq: nil, head: nil, sid: nil)
    format_frame(
      sse_event: SSE_EVENT_CLOSE,
      id: seq,
      envelope: envelope(evt: SSE_EVENT_CLOSE, seq: seq, sseq: sseq, head: head, sid: sid, pld: {reason: reason})
    )
  end

  # Test whether a string is safe to emit as raw UTF-8 inside an SSE
  # `data:` field per the WHATWG spec. Excludes:
  #
  # - U+000D CR (forbidden by SSE field grammar)
  # - C0 controls (U+0000-U+001F) except U+000A LF (handled by multi-line
  #   `data:`)
  # - C1 controls (U+007F-U+009F)
  # - Anything that isn't valid UTF-8
  #
  # JSON escapes control characters to `\uXXXX`, so envelopes are always
  # safe; this is for sources that write something else.
  #
  # @param str [String]
  # @return [Boolean]
  def self.sse_safe_utf8?(str)
    utf8 = (str.encoding == ::Encoding::ASCII_8BIT) ? str.dup.force_encoding(::Encoding::UTF_8) : str
    return false unless utf8.valid_encoding?

    utf8.each_codepoint do |cp|
      return false if cp == 0x000D
      return false if cp < 0x0020 && cp != 0x000A
      return false if cp.between?(0x007F, 0x009F)
    end
    true
  end

  # Detect Puma graceful shutdown from inside a worker thread.
  #
  # SIGTERM / SIGUSR1 go to the main thread only; a worker blocked in
  # `sleep` or `IO.select` doesn't see them. Puma stores the server in
  # `Thread.current.puma_server`, and `shutting_down?` is true once its
  # status is `:stop` or `:restart`. {StreamingBody} polls this on every
  # loop iteration, which needs no signal handlers and no Puma config.
  #
  # Returns false when not under Puma.
  #
  # @see https://github.com/puma/puma/issues/932
  def self.puma_shutting_down?
    return false unless defined?(Puma::Server)
    Puma::Server.current&.shutting_down? || false
  end

  # Reports an error Sossego handled instead of raising: a publish that failed
  # while reporting on a job, a hand-off that failed, a source that failed to
  # close. Logs it, and hands it to `Rails.error` (with `handled: true` and
  # source "sossego"), so error trackers subscribed to it see it.
  #
  # @param error [Exception]
  # @param message [String] what was being done, for the log
  # @param logger [Logger, nil]
  # @param context [Hash] passed to `Rails.error.report`
  # @return [nil]
  def self.report_error(error, message:, logger: nil, **context)
    logger&.error("#{message}: #{error.class}: #{error.message}")
    Rails.error.report(error, handled: true, source: "sossego", context: context) if defined?(Rails) && Rails.respond_to?(:error)
    nil
  end

  # @api private
  def self.fmt_of(event)
    (event.fmt if event.respond_to?(:fmt)) || DEFAULT_FMT
  end

  # @api private
  def self.utf8_text(value)
    text = value.to_s
    text = text.dup.force_encoding(::Encoding::UTF_8) unless text.encoding == ::Encoding::UTF_8
    raise UnknownEncoding, "a #{FMT_TEXT} payload must be valid UTF-8; publish it with fmt: \"#{FMT_BYTES}\"" unless text.valid_encoding?
    text
  end

  # @api private
  def self.gunzip(base64)
    Zlib.gunzip(Base64.strict_decode64(base64))
  end

  # @api private
  def self.gzip(string)
    io = StringIO.new("".b)
    gz = Zlib::GzipWriter.new(io)
    gz.write(string)
    gz.close
    io.string
  end
end

require_relative "sossego/stream"
require_relative "sossego/source"
require_relative "sossego/streaming_body"
require_relative "sossego/turbo_stream"
require_relative "sossego/publishing_helpers"
require_relative "sossego/enqueuing"
require_relative "sossego/javascript"
require_relative "sossego/engine"
