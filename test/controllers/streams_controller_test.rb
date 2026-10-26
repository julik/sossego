require "test_helper"

class Sossego::StreamsControllerTest < ActionController::TestCase
  # Production subclasses override #sossego_stream to compose a stream
  # from request state (Current.user, etc). Test subclass uses a class
  # accessor so each test can swap the stream without redefining.
  #
  # `body_options` stands in for a subclass's #sossego_body_options, and
  # `refusal` for a subclass that turns a request away before streaming.
  class TestStreamsController < Sossego::StreamsController
    cattr_accessor :next_stream
    cattr_accessor :body_options, default: {}
    cattr_accessor :refusal

    def show
      return refuse_stream(self.class.refusal) if self.class.refusal

      super
    end

    protected

    def sossego_stream
      self.class.next_stream
    end

    def sossego_body_options
      self.class.body_options
    end
  end

  tests TestStreamsController

  setup do
    Sossego::Event.delete_all
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw do
      get "/sossego_stream", to: "sossego/streams_controller_test/test_streams#show"
    end
    TestStreamsController.next_stream = Sossego::Stream.new("test:stream:1")
    TestStreamsController.body_options = {}
    TestStreamsController.refusal = nil
  end

  test "inherits from ActionController::Base" do
    assert_operator Sossego::StreamsController, :<, ActionController::Base
  end

  test "does NOT include ActionController::Live" do
    refute_includes Sossego::StreamsController.ancestors, ActionController::Live
  end

  test "provides #show as the default streaming action" do
    assert TestStreamsController.method_defined?(:show), "subclass should inherit #show"
  end

  test "default #sossego_stream raises NotImplementedError to surface misconfig" do
    bare = Class.new(Sossego::StreamsController).new
    assert_raises(NotImplementedError) { bare.send(:sossego_stream) }
  end

  test "sets streaming headers on the response" do
    get :show

    assert_equal "text/event-stream", response.headers["Content-Type"]
    assert_equal "keep-alive", response.headers["Connection"]
    assert_equal "identity", response.headers["Content-Encoding"]
    assert_equal "no", response.headers["X-Accel-Buffering"]
    assert_equal "no-cache, no-transform", response.headers["Cache-Control"] # as Rails sends it, after normalizing
  end

  test "sets Last-Modified to defeat Rack::ETag buffering" do
    get :show
    assert_match(/GMT\z/, response.headers["Last-Modified"])
  end

  test "Rack::Deflater lets the stream through uncompressed, a chunk at a time" do
    stream = Sossego::Stream.new("test:1:deflate")
    first = stream.publish("entity", {id: 7})
    second = stream.publish("entity", {id: 8})
    TestStreamsController.next_stream = stream

    app = Rack::Deflater.new(TestStreamsController.action(:show)) # the whole Rails response, Cache-Control rewriting included
    _status, headers, body = app.call(Rack::MockRequest.env_for("/sossego_stream", "HTTP_ACCEPT_ENCODING" => "gzip"))

    assert_equal "identity", headers["content-encoding"]
    chunks = []
    body.each do |c|
      chunks << c
      break if chunks.length >= 3
    end
    body.close
    assert_match(/\Aretry: \d+\n\n\z/, chunks[0])
    assert chunks[1].start_with?("event: sossego\nid: #{first.id}\n")
    assert chunks[2].start_with?("event: sossego\nid: #{second.id}\n")
  end

  test "assigns a Sossego::StreamingBody as the response body" do
    get :show
    assert_kind_of Sossego::StreamingBody, @controller.response_body
  end

  test "the body iterates and yields framed SSE chunks for events on the stream" do
    stream = Sossego::Stream.new("test:1:foo")
    first = stream.publish("entity", {id: 7})
    second = stream.publish("entity", {id: 8})

    TestStreamsController.next_stream = stream

    get :show

    chunks = []
    @controller.response_body.each do |c|
      chunks << c
      break if chunks.length >= 3   # retry directive + 2 events
    end

    assert_match(/\Aretry: \d+\n\n\z/, chunks[0])
    assert_includes chunks[1], "event: sossego\nid: #{first.id}\n"
    assert_includes chunks[2], "event: sossego\nid: #{second.id}\n"

    env1 = parse_envelope(chunks[1])
    assert_equal "entity", env1["evt"]    # application name in the envelope
    assert_equal first.id.to_s, env1["seq"]
    assert_equal 1, env1["sseq"]
    assert_equal second.id.to_s, env1["head"]
    assert_equal "test:1:foo", env1["sid"]
    assert_equal({"id" => 7}, env1["pld"])

    env2 = parse_envelope(chunks[2])
    assert_equal "entity", env2["evt"]
    assert_equal second.id.to_s, env2["seq"]
    assert_equal 2, env2["sseq"]
    assert_equal({"id" => 8}, env2["pld"])
  end

  test "a close stored with publish_close goes out as a close frame with its id, and the body stops after it" do
    stream = Sossego::Stream.new("test:1:foo")
    progress = stream.publish("progress", {done: 1})
    close = stream.publish_close(reason: "finished")
    after_close = stream.publish("progress", {done: 2})  # past the close: never sent
    TestStreamsController.next_stream = stream

    get :show

    chunks = []
    @controller.response_body.each { |c| chunks << c }

    assert_equal 3, chunks.length, "retry, the event, the close, and nothing after"
    assert chunks[1].start_with?("event: sossego\nid: #{progress.id}\n")
    assert chunks[2].start_with?("event: close\nid: #{close.id}\n")
    assert_equal(
      {"fmt" => "ejson", "evt" => "close", "seq" => close.id.to_s, "sseq" => 2, "head" => after_close.id.to_s, "sid" => "test:1:foo", "pld" => {"reason" => "finished"}},
      parse_envelope(chunks[2])
    )
  end

  test "a cursor that is not a valid id counts as none, and the stream still serves" do
    stream = Sossego::Stream.new("test:1:foo")
    ids = Array.new(2) { stream.publish("entity", {}).id.to_s }
    TestStreamsController.next_stream = stream

    ["abc", "", "12; DROP TABLE sossego_events"].each do |cursor|
      request.headers["Last-Event-ID"] = cursor
      get :show, params: {last_event_id: cursor}

      assert_nil @controller.last_event_id
      chunks = []
      @controller.response_body.each do |c|
        chunks << c
        break if chunks.length >= 3
      end
      assert_equal ids, chunks.drop(1).map { |c| parse_envelope(c).fetch("seq") }, "no cursor replays from the start"
    end
  end

  test "a valid cursor is passed through" do
    request.headers["Last-Event-ID"] = "42"

    get :show

    assert_equal "42", @controller.last_event_id
  end

  # Helper: pull the JSON envelope out of an event chunk's data: lines.
  def parse_envelope(chunk)
    data_lines = chunk.lines.select { |l| l.start_with?("data: ") }
    Sossego.decode_frame(data_lines.map { |l| l.sub(/\Adata: /, "").chomp }.join("\n"))
  end

  test "passes the subclass's sossego_body_options to the streaming body" do
    stream = Sossego::Stream.new("test:1:foo")
    newest = Array.new(3) { stream.publish("entity", {}) }.last
    TestStreamsController.next_stream = stream
    TestStreamsController.body_options = {ping_first: true, max_backlog: 100, retry_ms: 7_000}

    get :show

    chunks = []
    @controller.response_body.each do |c|
      chunks << c
      break if chunks.length >= 2
    end

    assert_equal "retry: 7000\n\n", chunks[0]
    assert chunks[1].start_with?("event: ping\n"), "ping_first must reach the body"
    assert_match(/"head": "#{newest.id}"/, chunks[1])
  end

  test "refuse_stream answers HTTP 200 with the streaming headers and one close frame" do
    TestStreamsController.refusal = "unauthenticated"

    get :show

    assert_response :ok
    assert_equal "text/event-stream", response.headers["Content-Type"]
    assert_equal "no", response.headers["X-Accel-Buffering"]
    assert_match(/GMT\z/, response.headers["Last-Modified"])
    assert response.body.start_with?("event: close\ndata: {"), "a refusal has no id line and no retry directive"
    assert response.body.end_with?("\n\n")
    assert_equal 1, response.body.scan(/^event: /).length
    assert_equal({"fmt" => "ejson", "evt" => "close", "pld" => {"reason" => "unauthenticated"}}, parse_envelope(response.body))
  end

  test "refuses in-band as forbidden when subclass returns nil from sossego_stream" do
    TestStreamsController.next_stream = nil

    get :show

    assert_response :ok
    assert_equal "text/event-stream", response.headers["Content-Type"]
    assert_equal 1, response.body.scan(/^event: /).length
    assert_equal({"fmt" => "ejson", "evt" => "close", "pld" => {"reason" => "forbidden"}}, parse_envelope(response.body))
  end

  test "marks the request as IO-bound for Puma once, when it serves a stream" do
    marks = 0
    @request.env["puma.mark_as_io_bound"] = -> { marks += 1 }

    get :show

    assert_kind_of Sossego::StreamingBody, @controller.response_body
    assert_equal 1, marks
  end

  test "skips the session write for a served stream and for a refusal" do
    get :show
    assert @request.session_options[:skip], "a served stream must not write the session"

    TestStreamsController.refusal = "unauthenticated"
    get :show
    assert @request.session_options[:skip], "a refusal must not write the session"
  end

  test "passes compress_above_bytes on, so a big payload goes out gzipped" do
    stream = Sossego::Stream.new("test:1:big")
    stream.publish("big", {text: "x" * 2_000})
    stream.publish("big_text", "y" * 2_000)
    stream.publish("small", {text: "x"})
    TestStreamsController.next_stream = stream
    TestStreamsController.body_options = {compress_above_bytes: 512}

    get :show
    chunks = []
    @controller.response_body.each do |c|
      chunks << c
      break if chunks.length >= 4
    end

    big, big_text, small = chunks.drop(1).map { |c| parse_envelope(c) }
    assert_equal "gz:ejson", big["fmt"]
    assert_equal({"text" => "x" * 2_000}, big["pld"])
    assert_equal "gz:text", big_text["fmt"]
    assert_equal "y" * 2_000, big_text["pld"]
    assert_equal "ejson", small["fmt"]
  end

  test "a row stored gzipped goes out as stored, compression on or off" do
    stream = Sossego::Stream.new("test:1:gz")
    stored = stream.publish("big", "z" * 2_000, fmt: "gz:text")
    TestStreamsController.next_stream = stream
    TestStreamsController.body_options = {compress_above_bytes: 10}

    get :show
    chunks = []
    @controller.response_body.each do |c|
      chunks << c
      break if chunks.length >= 2
    end

    raw = JSON.parse(chunks[1].lines.select { |l| l.start_with?("data: ") }.map { |l| l.sub(/\Adata: /, "").chomp }.join("\n"))
    assert_equal "gz:text", raw["fmt"]
    assert_equal stored.payload, raw["pld"]
  end
end
