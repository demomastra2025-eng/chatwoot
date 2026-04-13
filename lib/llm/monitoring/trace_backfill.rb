# frozen_string_literal: true

class Llm::Monitoring::TraceBackfill
  DEFAULT_BATCH_SIZE = 500
  DEFAULT_MAX_BATCHES = 10

  def initialize(scope: LlmEvent.all, batch_size: DEFAULT_BATCH_SIZE, max_batches: DEFAULT_MAX_BATCHES)
    @scope = scope
    @batch_size = batch_size
    @max_batches = max_batches
  end

  def call
    updated_events = 0
    processed_batches = 0

    @max_batches.times do
      batch_ids = next_batch_ids
      break if batch_ids.blank?

      updated_events += LlmEvent.where(id: batch_ids).update_all("trace_id = payload ->> 'trace_id'")
      processed_batches += 1
    end

    {
      processed_batches: processed_batches,
      updated_events: updated_events,
      has_remaining_events: next_batch_ids.present?
    }
  end

  private

  def next_batch_ids
    pending_scope.order(:id).limit(@batch_size).pluck(:id)
  end

  def pending_scope
    @scope.where(trace_id: nil)
          .where("payload ? 'trace_id'")
          .where("COALESCE(payload ->> 'trace_id', '') <> ''")
  end
end
