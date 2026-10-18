# frozen_string_literal: true

# Pretends to read a receipt, then fills the form in.
class DemoAnalysisJob < ActiveJob::Base
  include Sossego::PublishingHelpers

  def perform(stream_id:, fail: false)
    stream.publish_progress("Looking at the receipt...")
    sleep 1
    stream.publish_progress("Asking the model what it sees...")
    sleep 1.5
    raise ArgumentError, "the receipt is upside down" if fail

    stream.publish_warning("The date was hard to read, please check it") if rand < 0.3
    stream.publish_progress("Filling in the form...")
    stream.publish_field_prefill(
      "expense[vendor]" => "Café Sossego",
      "expense[amount]" => format("%.2f", rand(5.0..80.0)),
      "expense[currency]" => %w[EUR USD BRL].sample,
      "expense[date]" => Date.current.iso8601,
      "expense[paid]" => true
    )
  end
end
