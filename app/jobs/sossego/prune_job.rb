# frozen_string_literal: true

module Sossego
  # Deletes events older than {Sossego.retention}. Schedule it; a skipped
  # run costs nothing because the sweep is by age.
  #
  # Nothing is kept back: the cursor is the global row id, which never resets,
  # so a stream pruned empty resumes correctly and a client's old cursor still
  # sorts below every future row.
  #
  # Deletes in batches so a big backlog does not hold long locks.
  #
  # @example config/recurring.yml (Solid Queue)
  #   sossego_prune:
  #     class: Sossego::PruneJob
  #     schedule: every 30 minutes
  class PruneJob < ActiveJob::Base
    BATCH_SIZE = 10_000

    # @param older_than [ActiveSupport::Duration] defaults to {Sossego.retention}
    # @return [void]
    def perform(older_than: Sossego.retention)
      quietly do
        Sossego::Event
          .where(created_at: ...older_than.ago)
          .in_batches(of: BATCH_SIZE)
          .delete_all
      end
    end

    private

    def quietly(&)
      logger = ActiveRecord::Base.logger
      logger.respond_to?(:silence) ? logger.silence(&) : yield
    end
  end
end
