# frozen_string_literal: true

require "test_helper"
require "open3"

# `require "sossego"` outside Rails: the wire layer, the body and its source,
# without the engine and the routing stack it needs.
class Sossego::StandaloneTest < ActiveSupport::TestCase
  test "loads without Rails and streams from a source of its own" do
    script = <<~RUBY
      require "sossego"
      Source = Struct.new(:stream_id) do
        def fetch_after(cursor) = cursor ? [[], "1"] : [[Sossego::Source::EventTuple.new("1", 1, "hello", {"to" => "world"}, "ejson")], "1"]
      end
      body = Sossego::StreamingBody.new(source: Source.new("s"), logger: nil, max_connected_s: 0.01, sleeper: ->(_) {})
      frames = []
      body.each { |frame| frames << frame }
      puts frames.join
      puts defined?(Rails::Engine) ? "engine loaded" : "no engine"
      puts defined?(Sossego::Engine) ? "sossego engine loaded" : "no sossego engine"
    RUBY
    out, err, status = Open3.capture3("ruby", "-I", File.expand_path("../../lib", __dir__), "-e", script, chdir: File.expand_path("../..", __dir__))

    assert status.success?, err
    assert_includes out, "retry: 3000\n\n"
    assert_includes out, "event: sossego\nid: 1\n"
    assert_includes out, %("pld": {\n)
    assert_includes out, "no engine\nno sossego engine\n"
    assert_empty err
  end
end
