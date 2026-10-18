# frozen_string_literal: true

module Sossego
  module StreamsHelper
    # Path to {SignedStreamsController} for the stream, signed.
    #
    # @param stream [Sossego::Stream]
    # @param expires_in [ActiveSupport::Duration, nil]
    # @return [String]
    def sossego_signed_stream_path(stream, expires_in: nil)
      sossego.signed_stream_path(stream_id: stream.id, sig: stream.signature(expires_in: expires_in))
    end

    # Same as {#sossego_signed_stream_path}, as a full URL.
    def sossego_signed_stream_url(stream, expires_in: nil)
      sossego.signed_stream_url(stream_id: stream.id, sig: stream.signature(expires_in: expires_in))
    end
  end
end
