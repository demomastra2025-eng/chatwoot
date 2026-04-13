# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::TraceBackfill do
  describe '#call' do
    it 'backfills trace_id in batches without touching rows that are already populated' do
      pending_one = create(:llm_event, trace_id: nil, payload: { 'trace_id' => 'trace-1' })
      pending_two = create(:llm_event, trace_id: nil, payload: { 'trace_id' => 'trace-2' })
      existing = create(:llm_event, trace_id: 'trace-3', payload: { 'trace_id' => 'trace-3' })

      summary = described_class.new(batch_size: 1, max_batches: 1).call

      expect(summary).to include(
        processed_batches: 1,
        updated_events: 1,
        has_remaining_events: true
      )
      expect([pending_one.reload.trace_id, pending_two.reload.trace_id].compact.size).to eq(1)
      expect(existing.reload.trace_id).to eq('trace-3')
    end
  end
end
