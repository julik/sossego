# frozen_string_literal: true

# How long events are kept. Sossego::PruneJob deletes older ones; schedule it
# (see the README). A client that comes back after longer than this, say a
# laptop closed over a weekend, finds a gap in the stream and is told so
# (`onGap` in the JS client), so it can refetch instead of trusting a partial
# replay.
Sossego.retention = 24.hours

# Keep the events table in a database of its own, as Solid Queue does. Set it
# here, before the models load.
# Sossego.connects_to = {database: {writing: :sossego, reading: :sossego}}

# Which connection streams poll on. A stream polls every quarter second for up
# to half a minute. By default each poll borrows the connection Sossego::Event
# uses (your app's, unless connects_to is set above) and gives it back, so
# nothing is held between polls. To poll somewhere else, wrap the poll. Pick
# one of these, or write your own; `poll.call` runs the queries.
#
# A reading role, e.g. a replica, declared in config/database.yml and with
# `connects_to` on your ApplicationRecord:
#
#   Sossego.around_poll = ->(poll) { Sossego.connection_class.connected_to(role: :reading) { poll.call } }
#
# SQLite: the same database file opened read-only, in a pool of its own, so
# polling can never take the write lock. Nothing to declare in database.yml.
# Not in tests: a connection of its own can't see a test's transaction.
#
#   Sossego.poll_on_readonly_sqlite_connection! unless Rails.env.test?
#
# Anything else, e.g. a shard:
#
#   Sossego.around_poll = ->(poll) { ActiveRecord::Base.connected_to(shard: :events) { poll.call } }

# What signs the stream ids handed to the browser (Sossego::Stream#signature).
# Defaults to Rails.application.message_verifier("sossego_streams").
# Sossego.verifier = Rails.application.message_verifier("sossego_streams")

# PostgreSQL only: how long a publish waits for its stream's lock before it
# raises ActiveRecord::LockWaitTimeout. On SQLite the database's busy timeout
# applies instead.
# Rails.application.config.after_initialize do
#   Sossego::Event.lock_timeout_ms = 1_000
# end
