# frozen_string_literal: true

module Sossego
  # On SQLite, streams poll through a read-only connection to the same
  # database file (SQLITE_OPEN_READONLY), opened with the main connection's
  # settings for one poll and closed right after it. A stream stays open for
  # half a minute and polls four times a second; it never holds a connection
  # between polls, and nothing it does can take the database's write lock.
  #
  # Polls use the main connection instead when a separate one could not see
  # what they must:
  #
  # - in transactional tests, where the test's rows are uncommitted on a
  #   connection Rails pinned for the test (system tests share it across
  #   threads);
  # - when the polling thread is itself inside a transaction.
  #
  # Turned off with `Sossego.readonly_sqlite_polling = false`, and replaced by
  # `Sossego.around_poll` when that is set.
  module ReadonlyPolling
    ROLE = :sossego_readonly

    @lock = Mutex.new

    class << self
      # Whether polls should go through a read-only connection now.
      #
      # @return [Boolean]
      def applies?
        return false unless Sossego.readonly_sqlite_polling && Sossego::Event.sqlite?
        return false if in_memory?

        pool = Sossego::Event.connection_pool
        return false if pool.connections.any? { |connection| connection.respond_to?(:pinned) && connection.pinned }

        !pool.active_connection?&.transaction_open?
      end

      # Runs the block on a read-only connection opened for it, and closes the
      # connection when the block returns.
      #
      # @return the block's value
      def poll(&block)
        pool = readonly_pool
        connection = nil
        Sossego.connection_class.connected_to(role: ROLE) do
          pool.with_connection do |leased|
            connection = leased
            block.call
          end
        end
      ensure
        if connection
          pool.remove(connection)
          connection.disconnect!
        end
      end

      # The pool the read-only connections come from: the writing
      # connection's config with `readonly: true`, registered under {ROLE}.
      # It keeps no connections, since {.poll} closes each one.
      #
      # @api private
      def readonly_pool
        @lock.synchronize do
          handler = ActiveRecord::Base.connection_handler
          owner = Sossego.connection_class
          handler.retrieve_connection_pool(owner.name, role: ROLE) || begin
            writing = Sossego::Event.connection_db_config
            config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
              writing.env_name, "#{writing.name}_sossego_readonly", writing.configuration_hash.merge(readonly: true)
            )
            handler.establish_connection(config, owner_name: owner, role: ROLE)
          end
        end
      end

      private

      def in_memory?
        database = Sossego::Event.connection_db_config.database.to_s
        database == ":memory:" || database.include?("mode=memory")
      end
    end
  end
end
