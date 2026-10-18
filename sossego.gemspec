# frozen_string_literal: true

require_relative "lib/sossego/version"

Gem::Specification.new do |spec|
  spec.name = "sossego"
  spec.version = Sossego::VERSION
  spec.authors = ["Julik Tarkhanov"]
  spec.email = ["me@julik.nl"]
  spec.license = "MIT"

  spec.summary = "Server-Sent Events for Rails, backed by a database table"
  spec.description = "An append-only events table, a plain Rack streaming body that polls it, and a small JS client that resumes by cursor. No ActionController::Live, no pub/sub server."
  spec.homepage = "https://github.com/julik/sossego"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    Dir["{app,config,lib}/**/*", "README.md", "MANUAL.md", "LICENSE.md", "WIRE_FORMAT.md"].reject { |f| f.end_with?(".test.js") }
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "activejob", ">= 8.0"
  spec.add_dependency "actionpack", ">= 8.0"
  spec.add_dependency "railties", ">= 8.0"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "minitest-mock"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "sqlite3", ">= 2.1"
  spec.add_development_dependency "pg"
  spec.add_development_dependency "puma", ">= 6"
  spec.add_development_dependency "standard", "1.57.0"
end
