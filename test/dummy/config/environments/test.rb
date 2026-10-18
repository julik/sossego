# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.consider_all_requests_local = true
  config.action_controller.allow_forgery_protection = false
  config.action_dispatch.show_exceptions = :rescuable
  config.secret_key_base = "dummy-test-secret-key-base-for-sossego-tests-only"
  config.active_job.queue_adapter = :test
  config.active_support.deprecation = :stderr
end
