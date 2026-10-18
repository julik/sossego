# frozen_string_literal: true

require "test_helper"

# Transactions of the test's own, which the transactional test wrapper would
# otherwise hold open around every test.
class Sossego::PublishAfterCommitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  STREAM = Sossego::Stream.new("after_commit:1:test")

  setup { Sossego::Event.for_stream(STREAM.id).delete_all }
  teardown { Sossego::Event.for_stream(STREAM.id).delete_all }

  def published
    Sossego::Event.for_stream(STREAM.id).order(:id).pluck(:event_name)
  end

  test "publishes at once with no transaction open" do
    STREAM.publish_after_commit("changed", {id: 1})

    assert_equal ["changed"], published
  end

  test "inside a transaction, publishes after it commits and not before" do
    seen_inside = nil
    Sossego::Event.transaction do
      STREAM.publish_after_commit("changed", {id: 1})
      seen_inside = published
    end

    assert_empty seen_inside
    assert_equal ["changed"], published
  end

  test "waits for the outermost transaction, also on another model's connection" do
    ActiveRecord::Base.transaction do
      Sossego::Event.transaction(requires_new: true) do
        STREAM.publish_after_commit("changed")
      end
      assert_empty published, "a committed savepoint is not a commit"
    end

    assert_equal ["changed"], published
  end

  test "publishes nothing when the transaction rolls back" do
    Sossego::Event.transaction do
      STREAM.publish_after_commit("changed")
      raise ActiveRecord::Rollback
    end

    assert_empty published
  end

  test "a reserved name or an unknown fmt raises at the call, inside the transaction" do
    assert_raises(Sossego::ReservedEventName) do
      Sossego::Event.transaction { STREAM.publish_after_commit("message") }
    end
    assert_raises(Sossego::UnknownEncoding) do
      Sossego::Event.transaction { STREAM.publish_after_commit("changed", {}, fmt: "msgpack") }
    end
    assert_empty published
  end

  test "keeps the fmt it was given" do
    STREAM.publish_after_commit("thumb", "\x00\xFF".b, fmt: :bytes)

    assert_equal ["bytes"], Sossego::Event.for_stream(STREAM.id).pluck(:fmt)
  end

  test "hands a failed publish to on_error instead of raising" do
    errors = []
    Sossego::Event.stub(:publish, ->(**) { raise ActiveRecord::LockWaitTimeout, "busy" }) do
      Sossego::Event.transaction do
        STREAM.publish_after_commit("changed", on_error: ->(e) { errors << e })
      end
    end

    assert_equal ["busy"], errors.map(&:message)
  end

  test "without on_error, a failed publish raises after the commit, which stands" do
    counter = Counter.create!(name: "after-commit-test")
    Sossego::Event.stub(:publish, ->(**) { raise ActiveRecord::LockWaitTimeout, "busy" }) do
      assert_raises(ActiveRecord::LockWaitTimeout) do
        Counter.transaction do
          counter.update!(value: 7)
          STREAM.publish_after_commit("changed")
        end
      end
    end

    assert_equal 7, counter.reload.value
  ensure
    counter&.destroy
  end
end
