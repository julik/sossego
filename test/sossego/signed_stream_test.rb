# frozen_string_literal: true

require "test_helper"

class Sossego::SignedStreamTest < ActiveSupport::TestCase
  test "random makes a task stream with an unguessable middle part" do
    a = Sossego::Stream.random
    b = Sossego::Stream.random

    assert_match(/\Atask:[0-9a-z]{12}:progress\z/, a.id)
    refute_equal a, b
    assert_match(/\Ajob:[0-9a-z]{12}:tokens\z/, Sossego::Stream.random(:tokens, namespace: :job).id)
  end

  test "a signature verifies for its own stream id only" do
    stream = Sossego::Stream.random
    sig = stream.signature

    assert_equal stream, Sossego::Stream.verified(stream.id, sig)
    assert_nil Sossego::Stream.verified(Sossego::Stream.random.id, sig)
    assert_nil Sossego::Stream.verified(stream.id, "#{sig}x")
    assert_nil Sossego::Stream.verified(stream.id, nil)
    assert_nil Sossego::Stream.verified(nil, sig)
  end

  test "a signature with an expiry stops verifying once it expires" do
    stream = Sossego::Stream.random
    sig = stream.signature(expires_in: 1.minute)

    assert_equal stream, Sossego::Stream.verified(stream.id, sig)
    travel 2.minutes do
      assert_nil Sossego::Stream.verified(stream.id, sig)
    end
  end

  test "verified_from_url reads the stream from a signed stream path or URL" do
    stream = Sossego::Stream.random
    path = Sossego::Engine.routes.url_helpers.signed_stream_path(stream_id: stream.id, sig: stream.signature)

    assert_equal stream, Sossego::Stream.verified_from_url(path)
    assert_equal stream, Sossego::Stream.verified_from_url("https://example.com#{path}")
    assert_nil Sossego::Stream.verified_from_url("/sossego/streams/#{stream.id}?sig=nope")
    assert_nil Sossego::Stream.verified_from_url("ht tp://not a url")
    assert_nil Sossego::Stream.verified_from_url(nil)
  end
end
