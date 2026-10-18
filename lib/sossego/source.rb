# frozen_string_literal: true

module Sossego
  # Pull-based source that reads from a {Sossego::Stream}. The
  # {StreamingBody} drives the polling loop; this class just provides
  # `fetch_after(cursor)` and exposes the stream id.
  #
  # Pull-based (rather than yield-based) so the body can interleave
  # heartbeat emission and deadline checks between fetches - without
  # this, quiet streams would never emit pings or check the deadline
  # because the source's loop would block in `sleep` indefinitely.
  #
  # Cursors are event ids, handed over as strings and placed in
  # `WHERE id > ?` without being parsed. Each fetch:
  #
  # - Runs one query unless the batch is full. The head comes from the
  #   batch itself (see {#fetch_after}); `MAX(id)` is only queried when
  #   the batch hit its limit and may not have reached the head.
  # - Bypasses the Rails query cache (`uncached`) - without this, the
  #   per-request cache would return the first poll's empty result for
  #   every subsequent poll within the same long-lived request.
  #   CORRECTNESS, not just hygiene.
  # - Silences the AR SQL logger - one line per poll per open stream
  #   drowns real signal.
  # - Leaves no connection leased. Each query checks a connection out and
  #   returns it, so the streaming thread holds none while it sleeps
  #   between polls - as long as nothing earlier on the thread took a
  #   sticky lease (`lease_connection`), which would be held for the whole
  #   stream.
  # - Runs inside {Sossego.around_poll} when one is set; otherwise, on
  #   SQLite, on a read-only connection opened for the poll ({ReadonlyPolling}).
  class Source
    DEFAULT_BATCH_LIMIT = 100

    # One stored row as the body reads it: `seq` is the cursor (the row id
    # as a string), `sseq` the stream sequence, and `pld` the payload in the
    # wire form its `fmt` names.
    EventTuple = Struct.new(:seq, :sseq, :event_name, :pld, :fmt)

    attr_reader :stream_id

    # @param stream [Sossego::Stream]
    # @param batch_limit [Integer] max events fetched per fetch
    def initialize(stream, batch_limit: DEFAULT_BATCH_LIMIT)
      @stream = stream
      @stream_id = stream.id
      @batch_limit = batch_limit
    end

    # Fetch events after the given cursor.
    #
    # The head is derived from the batch when the batch is known to reach it:
    # an empty batch means the stream is still at `cursor`, and a batch
    # under the limit ends at the head. Only a full batch, or an empty one
    # with no cursor to report, reads the head from the database.
    #
    # @param cursor [String, nil] an event id; nil for none, which fetches
    #   from the stream's first retained event
    # @return [Array(Array<EventTuple>, String)] events and the
    #   stream's head as of this fetch (the "head" hint)
    def fetch_after(cursor)
      events, head = quietly do
        batch = @stream.events_after(cursor).limit(@batch_limit).to_a
        head = if batch.length < @batch_limit
          batch.last&.id || cursor || @stream.head
        else
          @stream.head
        end
        [batch, head]
      end

      tuples = events.map { |ev| EventTuple.new(ev.id.to_s, ev.sseq, ev.event_name, *ev.wire_pld_and_fmt) }
      [tuples, head.to_s]
    end

    # The stream's head cursor, read from the database. {StreamingBody}
    # asks once per connection, for the first ping and the starting cursor;
    # after that the head comes from {#fetch_after}.
    #
    # @return [String]
    def head
      quietly { @stream.head }.to_s
    end

    # Where a connection resuming from `cursor` starts, so that it replays
    # at most `max_backlog` events. One query.
    #
    # @param cursor [String] an event id
    # @param max_backlog [Integer]
    # @return [String]
    def backlog_start(cursor, max_backlog)
      quietly { @stream.backlog_start(cursor, max_backlog) }.to_s
    end

    # Default no-op; sources with subscriptions / queues override.
    def close
    end

    private

    # Runs a read past the request's query cache, without SQL log lines, and
    # inside {Sossego.around_poll} when one is configured.
    def quietly(&block)
      read = proc { Sossego::Event.uncached(&block) }
      poll = if Sossego.around_poll
        proc { Sossego.around_poll.call(read) }
      elsif ReadonlyPolling.applies?
        proc { ReadonlyPolling.poll(&read) }
      else
        read
      end

      logger = ActiveRecord::Base.logger
      logger.respond_to?(:silence) ? logger.silence(&poll) : poll.call
    end
  end
end
