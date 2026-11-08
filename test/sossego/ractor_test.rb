# frozen_string_literal: true

require "test_helper"

# The wire layer - envelopes, frames, the format registries - runs in any
# Ractor. The streaming body does not: it reads the database through Active
# Record, which lives on the main Ractor.
class Sossego::RactorTest < ActiveSupport::TestCase
  # Lambdas with a module for their self, which a Ractor can share
  module Upcase
    ENCODE = ->(value) { value.to_s.upcase }
    DECODE = ->(pld) { pld.downcase }
  end

  VALUES = {
    "ejson" => {"done" => 5, "names" => ["a", "b"]},
    "text" => "héllo\nworld",
    "bytes" => "\x00\xFF\x10".b,
    "gz:ejson" => {"done" => 5, "names" => ["a", "b"]},
    "gz:text" => "héllo\nworld",
    "gz:bytes" => "\x00\xFF\x10".b
  }.freeze

  test "the registries are shareable, with every built-in format in them" do
    assert Ractor.shareable?(Sossego.encoders)
    assert Ractor.shareable?(Sossego.decoders)
    assert_equal VALUES.keys.sort, Sossego.encoders.keys.sort
    assert_equal VALUES.keys.sort, Sossego.decoders.keys.sort
  end

  test "every built-in format round-trips through a frame formatted in one Ractor and decoded in another" do
    VALUES.each do |fmt, value|
      pld = Sossego.encoders.fetch(fmt).call(value)
      frame = in_ractor(fmt, pld) do |fmt, pld|
        Sossego.format_event_frame(Sossego::Source::EventTuple.new("7", 2, "progress", pld, fmt), head: "7", sid: "task:1")
      end
      assert_equal Sossego.format_event_frame(Sossego::Source::EventTuple.new("7", 2, "progress", pld, fmt), head: "7", sid: "task:1"), frame

      decoded = in_ractor(data_text(frame)) { |data| Sossego.decode_frame(data) }
      assert_equal value, decoded.fetch("pld"), fmt
      assert_equal({"fmt" => fmt, "evt" => "progress", "seq" => "7", "sseq" => 2, "head" => "7", "sid" => "task:1"}, decoded.except("pld"))
    end
  end

  test "pings and closes format in a Ractor" do
    time = Time.utc(2026, 11, 8, 12, 0, 0)
    assert_equal Sossego.format_ping_frame(head: "9", time: time), in_ractor(time) { |time| Sossego.format_ping_frame(head: "9", time: time) }
    assert_equal Sossego.format_close_frame(reason: "forbidden"), in_ractor { Sossego.format_close_frame(reason: "forbidden") }
  end

  test "a format registered with shareable callables works in a Ractor" do
    Sossego.register_fmt("upcase", encoder: Upcase::ENCODE, decoder: Upcase::DECODE)
    assert Ractor.shareable?(Sossego.encoders)

    envelope = in_ractor { Sossego.envelope(evt: "x", pld: "hello", fmt: "upcase") }
    assert_equal "HELLO", envelope.fetch(:pld)
    assert_equal "hello", in_ractor { Sossego.decode_frame(%({"fmt": "upcase", "evt": "x", "pld": "HELLO"})) }.fetch("pld")
  ensure
    Sossego.unregister_fmt("upcase")
    assert Ractor.shareable?(Sossego.encoders)
  end

  test "a format whose callables cannot be shared keeps the registries on the main Ractor" do
    Sossego.register_fmt("local", encoder: ->(value) { value.to_s }, decoder: ->(pld) { pld })
    refute Ractor.shareable?(Sossego.encoders)
    assert Sossego.encoders.frozen?
    assert_equal "x", Sossego.envelope(evt: "x", pld: "x", fmt: "local").fetch(:pld)

    error = assert_raises(Ractor::RemoteError) { in_ractor { Sossego.format_close_frame(reason: "forbidden") } }
    assert_kind_of Ractor::IsolationError, error.cause
  ensure
    Sossego.unregister_fmt("local")
    assert Ractor.shareable?(Sossego.encoders)
  end

  private

  def in_ractor(*args, &block)
    experimental = Warning[:experimental]
    Warning[:experimental] = false
    ractor = Ractor.new(*args, &block)
    ractor.respond_to?(:value) ? ractor.value : ractor.take
  ensure
    Warning[:experimental] = experimental
  end

  def data_text(frame)
    frame.lines.grep(/\Adata: /).map { |line| line.delete_prefix("data: ").chomp }.join("\n")
  end
end
