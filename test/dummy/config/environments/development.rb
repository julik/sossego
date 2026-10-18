# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = true
  config.consider_all_requests_local = true
  config.server_timing = true
  config.secret_key_base = "dummy-development-secret-key-base-for-sossego-demos-only"
  config.active_record.migration_error = :page_load
  config.log_level = :info
end
