# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/sossego/install/install_generator"

class Sossego::InstallGeneratorTest < Rails::Generators::TestCase
  tests Sossego::InstallGenerator
  destination File.expand_path("../../tmp/generator_test", __dir__)

  setup do
    prepare_destination
    mkdir_p File.join(destination_root, "config")
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  test "creates the events table migrations and mounts the engine" do
    run_generator

    assert_migration "db/migrate/create_sossego_events.rb" do |migration|
      assert_match(/create_table :sossego_events/, migration)
      assert_match(/t\.bigint :sseq, null: false/, migration)
      assert_match(/add_index :sossego_events, \[:stream_id, :sseq\], unique: true/, migration)
      assert_match(/ActiveRecord::Migration\[\d+\.\d+\]/, migration)
    end
    assert_migration "db/migrate/add_fmt_to_sossego_events.rb" do |migration|
      assert_match(/add_column :sossego_events, :fmt, :string, null: false, default: "ejson"/, migration)
    end
    assert_file "config/routes.rb", /mount Sossego::Engine => "\/sossego"/
    assert_file "config/initializers/sossego.rb" do |initializer|
      assert_match(/^Sossego.retention = 24.hours$/, initializer)
      assert_match(/^#   Sossego.poll_on_readonly_sqlite_connection! unless Rails.env.test\?$/, initializer)
      assert_match(/^#   Sossego.around_poll = ->\(poll\) \{ Sossego.connection_class.connected_to\(role: :reading\) \{ poll.call \} \}$/, initializer)
    end
  end

  test "the initializer it writes loads, and sets the retention" do
    run_generator
    previous = Sossego.retention
    Sossego.retention = nil

    load File.join(destination_root, "config/initializers/sossego.rb")

    assert_equal 24.hours, Sossego.retention
  ensure
    Sossego.retention = previous
  end

  test "with --skip, an app that has the table gets only the migrations it lacks" do
    mkdir_p File.join(destination_root, "db/migrate")
    File.write(File.join(destination_root, "db/migrate/20261002081011_create_sossego_events.rb"), "# Cora's\n")
    File.write(File.join(destination_root, "config/routes.rb"), %(Rails.application.routes.draw do\n  mount Sossego::Engine => "/sossego"\nend\n))
    mkdir_p File.join(destination_root, "config/initializers")
    File.write(File.join(destination_root, "config/initializers/sossego.rb"), "Sossego.retention = 6.hours\n")

    run_generator ["--skip"]

    assert_equal "# Cora's\n", File.read(File.join(destination_root, "db/migrate/20261002081011_create_sossego_events.rb"))
    assert_migration "db/migrate/add_fmt_to_sossego_events.rb"
    assert_equal "Sossego.retention = 6.hours\n", File.read(File.join(destination_root, "config/initializers/sossego.rb"))
    assert_equal 1, File.read(File.join(destination_root, "config/routes.rb")).scan("Sossego::Engine").length
  end
end
