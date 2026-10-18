# frozen_string_literal: true

# Ends by sending the browser to the page it prepared. Its stream exists for
# this one task, so the job closes it when it is done.
class DemoPreparationJob < ActiveJob::Base
  include Sossego::Reporting

  self.sossego_close_stream = true

  def perform(stream_id:)
    ["Gathering the numbers...", "Laying out the pages...", "Almost there..."].each do |message|
      publish_progress(message)
      sleep 1
    end
    publish_visit(Rails.application.routes.url_helpers.prepared_progress_path)
  end
end
