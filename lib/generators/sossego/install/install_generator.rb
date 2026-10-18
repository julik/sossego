# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Sossego
  # rails generate sossego:install
  #
  # Writes every migration the events table needs, in order, an initializer
  # with the settings, and mounts the engine. An app that installed an
  # earlier version runs it with `--skip` to get only what it does not have
  # yet; its initializer is left alone.
  class InstallGenerator < Rails::Generators::Base
    include ActiveRecord::Generators::Migration

    source_root File.expand_path("templates", __dir__)

    MIGRATIONS = %w[
      create_sossego_events
      add_fmt_to_sossego_events
    ]

    def create_migration_files
      MIGRATIONS.each do |name|
        migration_template "#{name}.rb.erb", File.join(db_migrate_path, "#{name}.rb")
      end
    end

    def create_initializer
      template "initializer.rb.erb", "config/initializers/sossego.rb"
    end

    def mount_engine
      routes = File.join(destination_root, "config/routes.rb")
      return if File.exist?(routes) && File.read(routes).include?("Sossego::Engine")

      route %(mount Sossego::Engine => "/sossego")
    end

    private

    def migration_version
      "[#{ActiveRecord::VERSION::STRING.to_f}]"
    end
  end
end
