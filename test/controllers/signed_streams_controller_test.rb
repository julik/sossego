# frozen_string_literal: true

require "test_helper"

class Sossego::SignedStreamsControllerTest < ActionDispatch::IntegrationTest
  def frames(body)
    body.split("\n\n").map { |f| f + "\n\n" }
  end

  def data_text(frame)
    frame.lines.select { |l| l.start_with?("data: ") }.map { |l| l.sub(/\Adata: /, "").chomp }.join("\n")
  end

  test "refuses in-band, with HTTP 200 and a close frame, for a missing or wrong signature" do
    stream = Sossego::Stream.random

    ["/sossego/streams/#{stream.id}", "/sossego/streams/#{stream.id}?sig=forged"].each do |path|
      get path

      assert_response :ok
      assert_equal "text/event-stream", response.media_type
      assert_equal({"fmt" => "ejson", "evt" => "close", "pld" => {"reason" => "forbidden"}}, Sossego.decode_frame(data_text(response.body)))
    end
  end

  test "replays the stream from its first event to a connection without a cursor, up to a stored close" do
    stream = Sossego::Stream.random
    stream.publish("progress", "Queued...")
    stream.publish("progress", "Working...")
    stream.publish_close(reason: "finished")

    get helper_path(stream)

    assert_response :ok
    sent = frames(response.body).reject { |f| f.start_with?("retry:") }
    envelopes = sent.map { |f| Sossego.decode_frame(data_text(f)) }
    assert_equal ["progress", "progress", "close"], envelopes.map { |e| e["evt"] }
    assert_equal ["Queued...", "Working...", {"reason" => "finished"}], envelopes.map { |e| e["pld"] }
  end

  test "never writes the session" do
    stream = Sossego::Stream.random
    stream.publish_close(reason: "finished")

    get helper_path(stream)

    assert_nil response.headers["Set-Cookie"]
  end

  private

  def helper_path(stream)
    Sossego::Engine.routes.url_helpers.signed_stream_path(stream_id: stream.id, sig: stream.signature)
  end
end
