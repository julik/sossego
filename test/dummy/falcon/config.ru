# frozen_string_literal: true

# The dummy app under Falcon, booted the way production boots it: no code
# reloading (so no interlock), eager loaded, and Rails' per-request state kept
# per fiber. What the Falcon paragraph of MANUAL.md was measured with:
#
#   createdb sossego_load
#   cd test/dummy
#   export RAILS_ENV=load SECRET_KEY_BASE_DUMMY=1 DATABASE_URL="postgres://localhost/sossego_load?pool=50"
#   bin/rails db:schema:load
#   bundle exec falcon serve --bind http://127.0.0.1:3777 --count 1 --no-restart --config falcon/config.ru
#   bundle exec ruby falcon/sse_load.rb 1000          # in another shell
#   bin/rails runner 'Counter::STREAM.publish("tick", {})'  # and another
require_relative "../config/application"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.active_support.isolation_level = :fiber
  config.log_level = :warn
end
Rails.application.initialize!

run Rails.application
