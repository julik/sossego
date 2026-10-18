# frozen_string_literal: true

require "test_helper"

# Separate connections can't see a test's own transaction, so these commit.
class Sossego::PollingConnectionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  STREAM = Sossego::Stream.new("polling:1:test")

  setup { Sossego::Event.for_stream(STREAM.id).delete_all }

  teardown do
    Sossego.around_poll = nil
    Sossego::Event.for_stream(STREAM.id).delete_all
    ActiveRecord::Base.connection_handler.remove_connection_pool(Sossego.connection_class.name, role: :sossego_readonly)
    ActiveRecord::Base.connection_handler.remove_connection_pool(Sossego.connection_class.name, role: :reading)
  end

  def poll
    Sossego::Source.new(STREAM).fetch_after(nil).first.map(&:event_name)
  end

  test "without around_poll, polls on the connection Sossego::Event has" do
    STREAM.publish("a")

    assert_equal ["a"], poll
  end

  test "around_poll wraps every poll and passes its result through" do
    calls = 0
    Sossego.around_poll = ->(poll) {
      calls += 1
      poll.call
    }
    STREAM.publish("a")

    assert_equal ["a"], poll
    assert_operator calls, :>=, 1
  end

  test "connection_class is ActiveRecord::Base unless the events table has a database of its own" do
    assert_equal ActiveRecord::Base, Sossego.connection_class
  end

  test "poll_on_readonly_sqlite_connection! polls a read-only copy of the database, which sees committed events" do
    skip_unless_sqlite
    Sossego.poll_on_readonly_sqlite_connection!
    STREAM.publish("a")

    assert_equal ["a"], poll
    STREAM.publish("b")
    assert_equal ["a", "b"], poll
  end

  test "the read-only copy cannot write" do
    skip_unless_sqlite
    Sossego.poll_on_readonly_sqlite_connection!

    error = assert_raises(ActiveRecord::StatementInvalid) do
      Sossego.around_poll.call(-> { Sossego::Event.connection.execute("DELETE FROM sossego_events") })
    end
    assert_match(/readonly/i, error.message)
  end

  test "polls through the copy, not the writing connection" do
    skip_unless_sqlite
    Sossego.poll_on_readonly_sqlite_connection!
    seen = nil
    Sossego.around_poll.call(-> { seen = Sossego::Event.connection.pool.db_config.name })

    assert_match(/sossego_readonly\z/, seen)
    refute_match(/sossego_readonly/, Sossego::Event.connection.pool.db_config.name)
  end

  test "poll_on_readonly_sqlite_connection! refuses a database that is not SQLite" do
    skip_unless_postgres
    Sossego.poll_on_readonly_sqlite_connection!

    assert_raises(ArgumentError) { poll }
  end

  test "the initializer's reading-role recipe polls on the app's reading role" do
    # What `connects_to database: {writing: ..., reading: ...}` on an app's
    # primary ApplicationRecord registers
    writing = Sossego::Event.connection_db_config
    reading = ActiveRecord::DatabaseConfigurations::HashConfig.new(writing.env_name, "replica", writing.configuration_hash)
    ActiveRecord::Base.connection_handler.establish_connection(reading, owner_name: ActiveRecord::Base, role: :reading)

    seen = nil
    Sossego.around_poll = ->(poll) { Sossego.connection_class.connected_to(role: :reading) { poll.call } }
    STREAM.publish("a")
    Sossego.around_poll.call(-> { seen = Sossego::Event.connection.pool.db_config.name })

    assert_equal "replica", seen
    assert_equal ["a"], poll
  end
end
