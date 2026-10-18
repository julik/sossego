# frozen_string_literal: true

module Sossego
  # ActiveRecord model over the `sossego_events` table. The unit of
  # storage for everything sossego streams.
  #
  # ## Schema (see the install generator's migration)
  #
  # - `id` - the cursor. Global across streams, increasing in commit order
  #   within a stream, never reused. A string on the wire (`seq`, the SSE
  #   `id:` line); Ruby never parses it, only places it in `WHERE id > ?`.
  # - `stream_id` - see {Sossego::Stream}
  # - `sseq` - the stream sequence: dense among a stream's retained rows,
  #   starting at 1. For ordering, gap detection and conditional appends,
  #   never a cursor. Starts over at 1 once a stream has been pruned empty.
  # - `event_name` - the application's event name, or `close` when written
  #   by the transport API ({Stream#publish_close})
  # - `fmt` - what `payload` holds, named as on the wire (see
  #   {Sossego.encoders}): `ejson`, `text`, `bytes`, or a `gz:` variant
  # - `payload` - the `pld` in wire form: JSON text for `ejson`, the text
  #   itself for `text`, base64 for `bytes` and every `gz:` format. Opaque
  #   to the storage layer.
  # - `created_at` - for retention by {Sossego::PruneJob}
  #
  # ## Publishing - serialized per stream
  #
  # {.publish} runs one transaction holding the stream's lock: it reads
  # `MAX(sseq)` and inserts `MAX(sseq) + 1`. The id comes from the column
  # default inside the lock, and COMMIT releases the lock.
  #
  # The lock makes id order, sseq order and commit order the same order
  # within a stream. Without it two publishers could take ids 7 and 8 and
  # commit 8 first; a poller reading `id > 6` in between would see 8, move
  # its cursor there, and skip 7 for good. With it there is no retry: the
  # `MAX` read sees every earlier commit of the stream and the insert cannot
  # collide. The unique `(stream_id, sseq)` index only guards against a
  # writer that bypassed the lock.
  #
  # What the lock is depends on the database:
  #
  # - PostgreSQL: `pg_advisory_xact_lock(hashtext(stream_id))`, bounded by
  #   `SET LOCAL lock_timeout` ({.lock_timeout_ms}). Past it Postgres raises
  #   `ActiveRecord::LockWaitTimeout` and nothing is written. Transaction
  #   scoped, so safe under PgBouncer transaction pooling.
  # - SQLite: the database's single write lock. Rails 8 opens transactions
  #   with `BEGIN IMMEDIATE`, so the `MAX` read already holds it and every
  #   commit, across all streams, happens in id order. The wait is bounded
  #   by the connection's busy `timeout:`. A host that switched the adapter
  #   to `default_transaction_mode: :deferred` loses that; the unique index
  #   then turns a race into an error instead of a skipped event.
  #
  # ## Conditional appends
  #
  # `after: n` appends only if the stream's current `sseq` is `n`, and
  # `after: 0` only if the stream has no retained rows. Otherwise
  # {Sossego::Conflict}, and nothing is written.
  #
  # ## Reserved names
  #
  # No row may carry a name in {Sossego::RESERVED_EVENT_NAMES}, except a
  # `close` written by the transport API. {.publish} raises
  # {Sossego::ReservedEventName} before touching the database; the
  # validation catches any other path.
  #
  # @example An application event
  #   Sossego::Event.publish(stream_id: "account:42:inbox", event_name: "inbox_changed", payload: {})
  #
  # @example Only as the stream's first event
  #   Sossego::Event.publish(stream_id: "task:7:progress", event_name: "queued", payload: {}, after: 0)
  class Event < ApplicationRecord
    self.table_name = "sossego_events"

    # How long {.publish} waits for the stream's lock on PostgreSQL, in
    # milliseconds, before it raises `ActiveRecord::LockWaitTimeout`.
    class_attribute :lock_timeout_ms, default: 1_000

    # Append-only: only created_at is ever set.
    self.record_timestamps = false

    # Set by {.publish} with `transport: true`; never stored.
    attribute :transport, :boolean, default: false

    validates :stream_id, :event_name, :fmt, presence: true
    validate :event_name_not_reserved
    validates :sseq, numericality: {only_integer: true, greater_than: 0}

    scope :for_stream, ->(stream_id) { where(stream_id: stream_id) }
    scope :after_cursor, ->(cursor) { where("id > ?", cursor) }

    # Append a new event to the stream, under the stream's lock.
    #
    # @param stream_id [String]
    # @param event_name [String] not in {Sossego::RESERVED_EVENT_NAMES}
    # @param payload [Object] for `ejson`, anything with a JSON
    #   representation; for `text`, a UTF-8 String; for `bytes`, a String
    # @param fmt [String, Symbol, nil] key of {Sossego.encoders}; nil for
    #   {Sossego.fmt_for} to choose `text` for a String and `ejson` for
    #   anything else
    # @param after [Integer, nil] append only if the stream's current `sseq`
    #   is this; 0 for "only if the stream has no retained rows"
    # @param transport [Boolean] true only from the transport API, which may
    #   store exactly `close`
    # @return [Sossego::Event]
    # @raise [Sossego::ReservedEventName] for a reserved name the caller may
    #   not use, before any query
    # @raise [Sossego::UnknownEncoding] for an unregistered `fmt`, or text
    #   that is not UTF-8, before any query
    # @raise [Sossego::Conflict] when `after` is given and is not the
    #   stream's current `sseq`
    # @raise [ActiveRecord::LockWaitTimeout] when the lock is not had in time
    def self.publish(stream_id:, event_name:, payload: nil, after: nil, fmt: nil, transport: false)
      unless publishable_name?(event_name, transport: transport)
        raise Sossego::ReservedEventName, "#{event_name.inspect} is reserved by Sossego"
      end

      fmt = (fmt || Sossego.fmt_for(payload)).to_s
      encoder = Sossego.encoders.fetch(fmt) { raise Sossego::UnknownEncoding, "unknown sossego fmt: #{fmt.inspect}" }
      pld = encoder.call(payload)
      payload_text = (fmt == Sossego::FMT_EJSON) ? JSON.generate(pld.as_json) : pld

      with_stream_lock(stream_id) do
        current = uncached { for_stream(stream_id).maximum(:sseq).to_i }
        if after && after != current
          raise Sossego::Conflict, "#{stream_id} is at sseq #{current}, not #{after}"
        end

        create!(
          stream_id: stream_id,
          sseq: current + 1,
          event_name: event_name,
          fmt: fmt,
          transport: transport,
          payload: payload_text,
          created_at: Time.current
        )
      end
    end

    # Runs the block in a transaction holding the stream's publish lock.
    #
    # Inside a caller's transaction this is a savepoint. On PostgreSQL
    # `SET LOCAL` survives releasing one, so the previous `lock_timeout` is
    # put back after the block and the caller's later statements keep their
    # own bound; rolling the savepoint back undoes the `SET LOCAL` by itself.
    #
    # @api private
    # @param stream_id [String]
    # @param shared [Boolean] take the lock in shared mode, which waits for
    #   an in-flight publish to the stream and blocks none of the readers
    # @return the block's value
    def self.with_stream_lock(stream_id, shared: false, &block)
      if postgres?
        with_advisory_lock(stream_id, shared: shared, &block)
      elsif sqlite?
        transaction(requires_new: true, &block)
      else
        raise NotImplementedError, "Sossego has no publish lock for the #{connection.adapter_name} adapter"
      end
    end

    # The head of a stream that has no retained rows: the id counter's
    # current value. On PostgreSQL the counter is read while holding the
    # stream's lock in shared mode: a publish to it still in flight already
    # has its id, and the counter would be at or above that id before the
    # row commits. A publish that holds the lock past {.lock_timeout_ms} is
    # not waited for. On SQLite there is nothing in flight to wait for.
    #
    # @api private
    # @return [Integer]
    def self.head_of_empty_stream(stream_id)
      return id_counter_value unless postgres?

      with_stream_lock(stream_id, shared: true) do
        for_stream(stream_id).maximum(:id) || id_counter_value
      end
    rescue ActiveRecord::LockWaitTimeout
      id_counter_value
    end

    # The id counter's current value: at least every id issued so far, and
    # below every id still to come. 0 before the first id is issued.
    #
    # @return [Integer]
    def self.id_counter_value
      if postgres?
        connection.select_value("SELECT pg_sequence_last_value(#{connection.quote(sequence_name)}::regclass)").to_i
      else
        # Rails creates SQLite primary keys with AUTOINCREMENT, which never
        # reuses an id and keeps its high-water mark here.
        connection.select_value("SELECT seq FROM sqlite_sequence WHERE name = #{connection.quote(table_name)}").to_i
      end
    end

    # Whether a client-sent cursor (`Last-Event-ID` or `?last_event_id=`) can
    # be an id of this table. {StreamsController#last_event_id} treats one
    # that is not as no cursor, so it never reaches `WHERE id > ?` and makes
    # the database fail a cast inside a streaming body.
    #
    # The default fits an integer primary key: decimal digits. A host whose
    # `sossego_events.id` is a UUID overrides this.
    #
    # @example A UUID host
    #   def Sossego::Event.cursor_valid?(cursor)
    #     cursor.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    #   end
    #
    # @param cursor [String]
    # @return [Boolean]
    def self.cursor_valid?(cursor)
      cursor.match?(/\A\d{1,19}\z/)
    end

    # Whether a row may be stored under this name.
    #
    # @param event_name [String]
    # @param transport [Boolean] whether the transport API is writing
    # @return [Boolean]
    def self.publishable_name?(event_name, transport: false)
      return true unless RESERVED_EVENT_NAMES.include?(event_name.to_s)

      transport && event_name.to_s == SSE_EVENT_CLOSE
    end

    # @api private
    def self.postgres?
      connection_db_config.adapter.to_s.match?(/postg/i)
    end

    # @api private
    def self.sqlite?
      connection_db_config.adapter.to_s.match?(/sqlite/i)
    end

    private_class_method def self.with_advisory_lock(stream_id, shared:)
      transaction(requires_new: true) do
        connection = self.connection
        nested = connection.open_transactions > 1
        timeout_before = connection.select_value("SELECT current_setting('lock_timeout')") if nested
        connection.execute("SET LOCAL lock_timeout = #{connection.quote("#{Integer(lock_timeout_ms)}ms")}")
        lock_function = shared ? "pg_advisory_xact_lock_shared" : "pg_advisory_xact_lock"
        connection.execute("SELECT #{lock_function}(hashtext(#{connection.quote(stream_id)}))")
        result = yield
        connection.execute("SET LOCAL lock_timeout = #{connection.quote(timeout_before)}") if nested
        result
      end
    end

    # The `pld` as it goes on the wire, and its `fmt`. A row stored as `ejson`
    # whose payload does not parse (written past {.publish}) goes out as
    # `text`.
    #
    # @return [Array(Object, String)]
    def wire_pld_and_fmt
      return [payload, fmt] unless fmt == Sossego::FMT_EJSON

      [JSON.parse(payload), fmt]
    rescue JSON::ParserError
      [payload, Sossego::FMT_TEXT]
    end

    # The application's value, decoded from the stored payload.
    #
    # @return [Object]
    def value
      pld, wire_fmt = wire_pld_and_fmt
      Sossego.decoders.fetch(wire_fmt) { raise Sossego::UnknownEncoding, "unknown sossego fmt: #{wire_fmt.inspect}" }.call(pld)
    end

    private

    def event_name_not_reserved
      return if self.class.publishable_name?(event_name, transport: transport)

      errors.add(:event_name, :exclusion, value: event_name)
    end
  end
end
