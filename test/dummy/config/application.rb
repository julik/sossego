# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)
require "sossego"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.active_job.queue_adapter = :async

    # Payloads are encrypted at rest in config/initializers/sossego.rb, so the
    # suite runs on encrypted rows. Fixed keys: this is the dummy app.
    config.active_record.encryption.primary_key = "sossego-dummy-primary-key"
    config.active_record.encryption.deterministic_key = "sossego-dummy-deterministic-key"
    config.active_record.encryption.key_derivation_salt = "sossego-dummy-key-derivation-salt"
  end
end
