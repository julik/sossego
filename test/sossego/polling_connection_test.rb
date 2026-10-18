# frozen_string_literal: true

require "test_helper"

# Separate connections can't see a test's own transaction, so these commit.
class Sossego::PollingConnectionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  STREAM = Sossego::Stream.new("polling:1:test")

  setup { Sossego::Event.for_stream(STREAM.id).delete_all }

  teardown do
    Sossego.around_poll = nil
    Sossego.readonly_sqlite_polling = true
    Sossego::Event.for_stream(STREAM.id).delete_all
    ActiveRecord::Base.connection_handler.remove_connection_pool(Sossego.connection_class.name, role: :reading)
  end

  def poll
    Sossego::Source.new(STREAM).fetch_after(nil).first.map(&:event_name)
  end

  def readonly_pool
    Sossego::ReadonlyPolling.readonly_pool
  end

  test "on SQLite a poll reads through a read-only connection, which sees committed events" do
    skip_unless_sqlite
    assert Sossego::ReadonlyPolling.applies?

    seen = nil
    STREAM.publish("a")
    Sossego::ReadonlyPolling.poll { seen = Sossego::Event.connection.pool.db_config.name }

    assert_match(/sossego_readonly\z/, seen)
    assert_equal ["a"], poll
    STREAM.publish("b")
    assert_equal ["a", "b"], poll
  end

  test "Source polls through it without being told to" do
    skip_unless_sqlite
    polls = 0
    original = Sossego::ReadonlyPolling.method(:poll)
    Sossego::ReadonlyPolling.stub(:poll, ->(&block) {
      polls += 1
      original.call(&block)
    }) do
      STREAM.publish("a")
      assert_equal ["a"], poll
    end

    assert_operator polls, :>=, 1
  end

  test "the read-only connection is closed after each poll" do
    skip_unless_sqlite
    connection = nil
    Sossego::ReadonlyPolling.poll { connection = Sossego::Event.connection }

    refute connection.active?, "the connection must be closed once the poll returns"
    assert_empty readonly_pool.connections
  end

  test "the read-only connection cannot write" do
    skip_unless_sqlite

    error = assert_raises(ActiveRecord::StatementInvalid) do
      Sossego::ReadonlyPolling.poll { Sossego::Event.connection.execute("DELETE FROM sossego_events") }
    end
    assert_match(/readonly/i, error.message)
  end

  test "polls through the main connection while this thread is in a transaction, which a separate connection could not see" do
    skip_unless_sqlite

    Sossego::Event.transaction do
      Sossego::Event.connection.execute("SELECT 1") # SQLite begins lazily
      STREAM.publish("uncommitted")
      refute Sossego::ReadonlyPolling.applies?
      assert_equal ["uncommitted"], poll
      raise ActiveRecord::Rollback
    end
  end

  test "can be turned off" do
    skip_unless_sqlite
    Sossego.readonly_sqlite_polling = false

    refute Sossego::ReadonlyPolling.applies?
  end

  test "around_poll wraps every poll instead, and passes its result through" do
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

  test "does not apply on other databases" do
    skip_unless_postgres

    refute Sossego::ReadonlyPolling.applies?
  end
end

# In a transactional test, Rails pins the connection the test writes on (and
# system tests share it across threads). A separate connection would not see
# the test's rows, so polls stay on the main connection.
class Sossego::PollingConnectionInTransactionalTestsTest < ActiveSupport::TestCase
  test "polls through the main connection while Rails holds a pinned test connection" do
    skip_unless_sqlite
    stream = Sossego::Stream.new("polling:2:pinned")
    stream.publish("from the test")

    refute Sossego::ReadonlyPolling.applies?
    assert_equal ["from the test"], Sossego::Source.new(stream).fetch_after(nil).first.map(&:event_name)
  end
end
