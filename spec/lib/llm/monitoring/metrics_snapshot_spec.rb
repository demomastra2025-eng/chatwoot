# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::MetricsSnapshot do
  describe '#call' do
    it 'builds a summarized monitoring snapshot from persisted llm events' do
      create(:llm_event, feature: 'assistant', model: 'gpt-4.1-mini', total_tokens: 100, estimated_cost: 0.0001, duration_ms: 200)
      create(:llm_event, feature: 'copilot', model: 'gpt-5.1', total_tokens: 200, estimated_cost: 0.0005, duration_ms: 400, error: true)
      create(:llm_event, event_name: 'llm.schema.invalid', schema_invalid: true, total_tokens: nil, estimated_cost: nil)
      create(:llm_event, event_name: 'llm.moderation.unavailable', status: 'unavailable', moderation_skipped: true, total_tokens: nil, estimated_cost: nil)
      create(
        :llm_event,
        event_name: 'llm.moderation.complete',
        status: 'flagged',
        blocked: true,
        reason: 'moderation_flagged',
        total_tokens: nil,
        estimated_cost: nil,
        payload: {
          stage: 'output',
          flagged_categories: %w[violence harassment]
        }
      )
      create(
        :llm_event,
        event_name: 'llm.safety.blocked',
        blocked: true,
        reason: 'custom_blocklist',
        payload: { stage: 'input', rule: 'password' },
        total_tokens: nil,
        estimated_cost: nil
      )
      create(:llm_event, event_name: 'llm.tool.complete', tool_failure: true, total_tokens: nil, estimated_cost: nil)
      create(:llm_event, event_name: 'llm.embedding.complete', feature: 'embedding', total_tokens: 50, estimated_cost: 0.0002)
      create(:llm_event, event_name: 'llm.transcription.complete', feature: 'audio_transcription', total_tokens: nil, estimated_cost: nil)

      snapshot = described_class.new.call

      expect(snapshot).to include(
        total_events: 9,
        request_count: 2,
        embedding_count: 1,
        transcription_count: 1,
        moderation_count: 2,
        blocked_count: 2,
        error_count: 1,
        moderation_skipped_count: 1,
        schema_invalid_count: 1,
        tool_failure_count: 1,
        total_tokens: 300,
        all_total_tokens: 350
      )
      expect(snapshot[:estimated_cost].to_f).to eq(0.0006)
      expect(snapshot[:total_estimated_cost].to_f).to eq(0.0008)
      expect(snapshot[:by_feature]).to eq('assistant' => 1, 'copilot' => 1)
      expect(snapshot[:by_model]).to eq('gpt-4.1-mini' => 1, 'gpt-5.1' => 1)
      expect(snapshot[:by_provider]).to eq('openai' => 2)
      expect(snapshot[:by_event_name]).to eq(
        'llm.chat.complete' => 2,
        'llm.embedding.complete' => 1,
        'llm.moderation.complete' => 1,
        'llm.moderation.unavailable' => 1,
        'llm.safety.blocked' => 1,
        'llm.schema.invalid' => 1,
        'llm.transcription.complete' => 1,
        'llm.tool.complete' => 1
      )
      expect(snapshot[:moderation_by_status]).to eq(
        'flagged' => 1,
        'unavailable' => 1
      )
      expect(snapshot[:moderation_by_stage]).to eq('output' => 1)
      expect(snapshot[:blocked_by_reason]).to eq(
        'custom_blocklist' => 1,
        'moderation_flagged' => 1
      )
      expect(snapshot[:flagged_categories]).to eq(
        'harassment' => 1,
        'violence' => 1
      )
      expect(snapshot[:last_event_at]).to be_present
    end
  end
end
