require "test_helper"

class SossegoTest < ActiveSupport::TestCase
  Row = Struct.new(:seq, :sseq, :event_name, :pld)

  # The `data:` text of a frame, its lines joined as the browser does.
  def data_text(frame)
    frame.lines.select { |l| l.start_with?("data: ") }.map { |l| l.sub(/\Adata: /, "").chomp }.join("\n")
  end

  # ----- envelope construction -----

  test "envelope writes the keys in wire order" do
    env = Sossego.envelope(evt: "entity", seq: "12345", sseq: 9, head: "17168", sid: "user:1:mail_messages", pld: {id: 7})

    assert_equal %i[fmt evt seq sseq head sid pld], env.keys
    assert_equal "ejson", env[:fmt]
    assert_equal "entity", env[:evt]
    assert_equal({id: 7}, env[:pld])
  end

  test "envelope leaves out the positional keys that are nil" do
    env = Sossego.envelope(evt: "close", pld: {reason: "flag_off"})

    assert_equal({fmt: "ejson", evt: "close", pld: {reason: "flag_off"}}, env)
  end

  test "envelope keeps a nil pld" do
    assert_equal({fmt: "ejson", evt: "x", pld: nil}, Sossego.envelope(evt: "x", pld: nil))
  end

  test "envelope runs pld through the encoder fmt names" do
    Sossego.encoders["upcase"] = ->(value) { value.to_s.upcase }

    assert_equal "HELLO", Sossego.envelope(fmt: "upcase", evt: "x", pld: "hello")[:pld]
  ensure
    Sossego.encoders.delete("upcase")
  end

  test "envelope raises on an unregistered fmt" do
    error = assert_raises(Sossego::UnknownEncoding) { Sossego.envelope(fmt: "gzip", evt: "x", pld: {}) }
    assert_match(/gzip/, error.message)
  end

  # ----- decode_frame -----

  test "decode_frame round-trips a frame written by format_event_frame" do
    frame = Sossego.format_event_frame(Row.new("119", 57, "inbox_changed", {"id" => 7}), head: "120", sid: "account:42:inbox")

    assert_equal(
      {"fmt" => "ejson", "evt" => "inbox_changed", "seq" => "119", "sseq" => 57, "head" => "120", "sid" => "account:42:inbox", "pld" => {"id" => 7}},
      Sossego.decode_frame(data_text(frame))
    )
  end

  test "decode_frame runs pld through the decoder fmt names" do
    Sossego.decoders["upcase"] = ->(pld) { pld.upcase }

    assert_equal "HELLO", Sossego.decode_frame(%({"fmt": "upcase", "evt": "x", "pld": "hello"}))["pld"]
  ensure
    Sossego.decoders.delete("upcase")
  end

  test "decode_frame raises on an unknown fmt" do
    error = assert_raises(Sossego::UnknownEncoding) { Sossego.decode_frame(%({"fmt": "weasel", "evt": "x", "pld": {}})) }
    assert_match(/weasel/, error.message)
  end

  test "decode_frame raises on a missing fmt" do
    assert_raises(Sossego::UnknownEncoding) { Sossego.decode_frame(%({"evt": "x", "pld": {}})) }
  end

  test "decode_frame raises on text that is not a JSON object" do
    assert_raises(JSON::ParserError) { Sossego.decode_frame("json:{}") }
    assert_raises(Sossego::UnknownEncoding) { Sossego.decode_frame("[1, 2]") }
  end

  # ----- format_frame -----

  test "format_frame writes the event line, the id line, and the envelope pretty-printed across data lines" do
    frame = Sossego.format_frame(sse_event: "sossego", id: "1", envelope: Sossego.envelope(evt: "x", seq: "1", sseq: 1, head: "1", sid: "s:1", pld: {"a" => 1}))

    assert frame.start_with?("event: sossego\nid: 1\ndata: {\n")
    assert frame.end_with?("\ndata: }\n\n"), "frame must end with the blank line"
    assert_operator frame.lines.count { |l| l.start_with?("data: ") }, :>, 1
  end

  test "format_frame leaves out the id line when the id is nil" do
    frame = Sossego.format_frame(sse_event: "ping", envelope: Sossego.envelope(evt: "ping", pld: {}))

    assert frame.start_with?("event: ping\ndata: {"), "the data lines follow the event line directly"
    assert_no_match(/^id:/, frame)
  end

  # ----- format_event_frame -----

  test "format_event_frame is a sossego frame whatever the event name, with the name as evt" do
    frame = Sossego.format_event_frame(Row.new("12345", 9, "entity", {"id" => 7, "in_inbox" => true}), head: "17168", sid: "user:1:mail_messages")

    assert frame.start_with?("event: sossego\nid: 12345\n"), "the application's name never rides the SSE slot"
    envelope = JSON.parse(data_text(frame))
    assert_equal %w[fmt evt seq sseq head sid pld], envelope.keys
    assert_equal "entity", envelope["evt"]
    assert_equal "12345", envelope["seq"]
    assert_equal 9, envelope["sseq"]
    assert_equal "17168", envelope["head"]
    assert_equal "user:1:mail_messages", envelope["sid"]
    assert_equal({"id" => 7, "in_inbox" => true}, envelope["pld"])
  end

  # ----- format_ping_frame -----

  test "format_ping_frame is a ping frame with head in the envelope and in pld, and no position" do
    frame = Sossego.format_ping_frame(head: "42", time: Time.utc(2026, 5, 3, 10, 0, 0))

    assert frame.start_with?("event: ping\ndata: {")
    assert_no_match(/^id:/, frame)
    assert_equal(
      {"fmt" => "ejson", "evt" => "ping", "head" => "42", "pld" => {"head" => "42", "time" => "2026-05-03T10:00:00Z"}},
      JSON.parse(data_text(frame))
    )
  end

  # ----- format_close_frame -----

  test "format_close_frame without a seq is a refusal with no id line and no position" do
    frame = Sossego.format_close_frame(reason: "over_budget")

    assert frame.start_with?("event: close\ndata: {")
    assert_no_match(/^id:/, frame)
    assert frame.end_with?("\n\n")
    assert_equal({"fmt" => "ejson", "evt" => "close", "pld" => {"reason" => "over_budget"}}, JSON.parse(data_text(frame)))
  end

  test "format_close_frame with a seq is a stored close with its position" do
    frame = Sossego.format_close_frame(reason: "finished", seq: "31", sseq: 12, head: "31", sid: "task:7:progress")

    assert frame.start_with?("event: close\nid: 31\n")
    assert_equal(
      {"fmt" => "ejson", "evt" => "close", "seq" => "31", "sseq" => 12, "head" => "31", "sid" => "task:7:progress", "pld" => {"reason" => "finished"}},
      JSON.parse(data_text(frame))
    )
  end

  # ----- reserved names -----

  test "RESERVED_EVENT_NAMES holds the substrate's SSE names and the browser's own" do
    assert_equal %w[sossego ping close open error message], Sossego::RESERVED_EVENT_NAMES
    assert Sossego::RESERVED_EVENT_NAMES.frozen?
  end

  # ----- sse_safe_utf8? predicate -----

  test "sse_safe_utf8? accepts plain ascii" do
    assert Sossego.sse_safe_utf8?("hello")
  end

  test "sse_safe_utf8? accepts LF (handled via multi-line data:)" do
    assert Sossego.sse_safe_utf8?("line1\nline2")
  end

  test "sse_safe_utf8? rejects CR" do
    refute Sossego.sse_safe_utf8?("before\rafter")
  end

  test "sse_safe_utf8? rejects NUL" do
    refute Sossego.sse_safe_utf8?("before\0after")
  end

  test "sse_safe_utf8? rejects tab (C0 control)" do
    refute Sossego.sse_safe_utf8?("col1\tcol2")
  end

  test "sse_safe_utf8? rejects DEL (start of C1 range)" do
    refute Sossego.sse_safe_utf8?("before\x7Fafter")
  end

  test "sse_safe_utf8? rejects invalid UTF-8 bytes" do
    refute Sossego.sse_safe_utf8?("\xFF".dup.force_encoding(Encoding::UTF_8))
  end

  test "sse_safe_utf8? accepts emoji and CJK" do
    assert Sossego.sse_safe_utf8?("Hello 👋 你好")
  end

  # ----- STREAMING_HEADERS -----

  test "STREAMING_HEADERS is frozen" do
    assert Sossego::STREAMING_HEADERS.frozen?
  end

  test "STREAMING_HEADERS contains the anti-buffering set" do
    h = Sossego::STREAMING_HEADERS
    assert_equal "text/event-stream", h["Content-Type"]
    assert_equal "no-cache, no-transform", h["Cache-Control"]
    assert_equal "keep-alive", h["Connection"]
    assert_equal "identity", h["Content-Encoding"]
    assert_equal "no", h["X-Accel-Buffering"]
  end

  # ----- puma_shutting_down? -----

  test "puma_shutting_down? returns false when not in a Puma worker" do
    refute Sossego.puma_shutting_down?
  end

  test "puma_shutting_down? returns true when registered server is shutting down" do
    skip "Puma::Server not loaded" unless defined?(Puma::Server)

    fake = Object.new
    def fake.shutting_down?
      true
    end

    Puma::Server.stub(:current, fake) do
      assert Sossego.puma_shutting_down?
    end
  end

  test "puma_shutting_down? returns false when registered server is up" do
    skip "Puma::Server not loaded" unless defined?(Puma::Server)

    fake = Object.new
    def fake.shutting_down?
      false
    end

    Puma::Server.stub(:current, fake) do
      refute Sossego.puma_shutting_down?
    end
  end

  # ----- payload formats -----

  test "every built-in fmt round-trips through its encoder and decoder" do
    {
      "ejson" => {"a" => [1, "two"]},
      "text" => "Olá, 42",
      "bytes" => "\x00\xFF\r\n".b,
      "gz:ejson" => {"html" => "<turbo-stream></turbo-stream>" * 40},
      "gz:text" => "Olá " * 200,
      "gz:bytes" => ("\x00\xFF".b * 300)
    }.each do |fmt, value|
      env = Sossego.envelope(fmt: fmt, evt: "x", pld: value)
      decoded = Sossego.decode_frame(JSON.generate(env))["pld"]

      assert_equal value, decoded, "#{fmt} must round-trip"
      assert_equal value.encoding, decoded.encoding, "#{fmt} must keep the encoding" if value.is_a?(String)
    end
  end

  test "the gz: formats are base64 of the gzipped content" do
    pld = Sossego.envelope(fmt: "gz:text", evt: "x", pld: "hello")[:pld]

    assert_equal "hello", Zlib.gunzip(Base64.strict_decode64(pld))
  end

  test "text refuses bytes that are not UTF-8" do
    assert_raises(Sossego::UnknownEncoding) { Sossego.envelope(fmt: "text", evt: "x", pld: "\xFF".b) }
  end

  test "fmt_for picks text for a String and ejson for anything else, never bytes" do
    assert_equal "text", Sossego.fmt_for("hi")
    assert_equal "text", Sossego.fmt_for("\xFF".b)
    assert_equal "ejson", Sossego.fmt_for({a: 1})
    assert_equal "ejson", Sossego.fmt_for(nil)
    assert_equal "ejson", Sossego.fmt_for(42)
  end

  test "format_event_frame writes a stored pld as it is, under the row's fmt" do
    row = Sossego::Source::EventTuple.new("5", 1, "thumb", "AP8=", "bytes")
    env = JSON.parse(data_text(Sossego.format_event_frame(row, head: "5", sid: "s:1")))

    assert_equal "bytes", env["fmt"]
    assert_equal "AP8=", env["pld"]
  end
end
