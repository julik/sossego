# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "standard/rake"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/dummy/**/*")
  t.warning = false
end

desc "Run the JavaScript tests (needs `npm install` first)"
task :test_js do
  sh "npx vitest run"
end

task default: [:test, :standard]
