# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::UsageLedger do
  let(:account) { create(:account) }

  describe '.record_event!' do
    it 'records one account-scoped usage row for an OpenRouter llm event' do
      event = create(
        :llm_event,
        account: account,
        event_name: 'llm.chat.complete',
        provider: 'openrouter',
        feature: 'assistant',
        model: 'openai/gpt-4o',
        status: 'success',
        request_id: 'request-1',
        trace_id: 'trace-1',
        session_id: 'session-1',
        prompt_tokens: 120,
        completion_tokens: 40,
        thinking_tokens: 7,
        total_tokens: 167,
        estimated_cost: 0.0012,
        duration_ms: 830,
        payload: {
          'openrouter_generation_id' => 'gen-1',
          'endpoint_provider' => 'OpenAI',
          'routing_profile' => 'tool_reliable',
          'openrouter_generation' => {
            'provider_name' => 'OpenAI',
            'model' => 'openai/gpt-4o-2026-05-30',
            'cached_tokens' => 13,
            'cost' => '0.0015'
          }
        }
      )

      expect { described_class.record_event!(event) }.to change(LlmUsageEvent, :count).by(1)

      usage = LlmUsageEvent.last
      expect(usage).to have_attributes(
        account_id: account.id,
        llm_event_id: event.id,
        event_name: 'llm.chat.complete',
        feature: 'assistant',
        provider: 'openrouter',
        actual_provider: 'OpenAI',
        requested_model: 'openai/gpt-4o',
        actual_model: 'openai/gpt-4o-2026-05-30',
        routing_profile: 'tool_reliable',
        status: 'success',
        prompt_tokens: 120,
        completion_tokens: 40,
        reasoning_tokens: 7,
        cached_tokens: 13,
        total_tokens: 167,
        duration_ms: 830,
        generation_id: 'gen-1',
        trace_id: 'trace-1',
        session_id: 'session-1',
        request_id: 'request-1'
      )
      expect(usage.estimated_cost.to_f).to eq(0.0015)
    end

    it 'upserts when generation metadata later enriches the source event' do
      event = create(:llm_event, account: account, provider: 'openrouter', model: 'openai/gpt-4o', estimated_cost: 0.001)
      described_class.record_event!(event)

      event.update!(
        model: 'openai/gpt-4o-2026-05-30',
        estimated_cost: 0.002,
        payload: event.payload.merge(
          'openrouter_generation_id' => 'gen-updated',
          'openrouter_generation' => {
            'provider_name' => 'OpenAI',
            'model' => 'openai/gpt-4o-2026-05-30',
            'cached_tokens' => 20,
            'cost' => '0.002'
          }
        )
      )

      expect { described_class.record_event!(event) }.not_to change(LlmUsageEvent, :count)

      usage = LlmUsageEvent.find_by!(llm_event_id: event.id)
      expect(usage).to have_attributes(
        actual_model: 'openai/gpt-4o-2026-05-30',
        cached_tokens: 20,
        generation_id: 'gen-updated'
      )
      expect(usage.estimated_cost.to_f).to eq(0.002)
    end

    it 'does not create usage rows for non-provider RCA/tool events' do
      event = create(:llm_event, event_name: 'llm.tool.complete', provider: nil, estimated_cost: nil)

      expect { described_class.record_event!(event) }.not_to change(LlmUsageEvent, :count)
    end
  end

  describe '.summary' do
    it 'returns local cost/token totals scoped by account and window' do
      create(
        :llm_usage_event,
        account: account,
        feature: 'assistant',
        estimated_cost: 0.50,
        total_tokens: 100,
        cached_tokens: 10,
        reasoning_tokens: 3,
        occurred_at: 2.hours.ago
      )
      create(
        :llm_usage_event,
        account: account,
        feature: 'knowledge',
        estimated_cost: 0.25,
        total_tokens: 50,
        cached_tokens: 5,
        reasoning_tokens: 0,
        occurred_at: 1.hour.ago
      )
      create(:llm_usage_event, account: create(:account), estimated_cost: 9.99, occurred_at: 30.minutes.ago)

      summary = described_class.summary(account: account, range: 1.day.ago..Time.current)

      expect(summary).to include(
        request_count: 2,
        total_tokens: 150,
        cached_tokens: 15,
        reasoning_tokens: 3
      )
      expect(summary[:estimated_cost].to_f).to eq(0.75)
      expect(summary[:by_feature]).to include(
        'assistant' => include(request_count: 1, estimated_cost: be_within(0.000001).of(0.50)),
        'knowledge' => include(request_count: 1, estimated_cost: be_within(0.000001).of(0.25))
      )
    end
  end
end
