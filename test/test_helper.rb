# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [File.expand_path("dummy/db/migrate", __dir__)]
require "rails/test_help"
require "minitest/mock"
require "puma"

ActiveRecord::Migration.maintain_test_schema!

class ActiveSupport::TestCase
  # Tests that only make sense on one database.
  def skip_unless_postgres
    skip "PostgreSQL only" unless Sossego::Event.postgres?
  end

  def skip_unless_sqlite
    skip "SQLite only" unless Sossego::Event.sqlite?
  end
end
