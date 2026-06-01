# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::AccountUsageSummary do
  describe '.call' do
    it 'summarizes account spend, runtime reliability, routing fallbacks, latency, and cached key health' do
      account = create(:account)
      current_time = Time.zone.parse('2026-05-31 12:00:00')

      allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return(
        {
          status: 'valid',
          configured: true,
          checked_at: current_time.iso8601,
          source: 'management_key',
          credits: {
            status: 'available',
            total_credits: '10.5',
            remaining_credits: '7.25'
          }
        }
      )

      create_usage_event(
        account: account,
        occurred_at: current_time - 1.hour,
        requested_model: 'openai/gpt-5.4',
        actual_model: 'openai/gpt-5.4',
        duration_ms: 100
      )
      create_usage_event(
        account: account,
        occurred_at: current_time - 2.hours,
        requested_model: 'moonshotai/kimi-k2.6',
        actual_model: 'openai/gpt-5.4-mini',
        duration_ms: 500
      )
      create_usage_event(
        account: account,
        occurred_at: current_time - 3.hours,
        status: 'error',
        error_code: 'provider_error',
        duration_ms: 900
      )
      create(
        :llm_event,
        account: account,
        provider: 'openrouter',
        event_name: 'llm.schema.invalid',
        schema_invalid: true,
        created_at: current_time - 30.minutes
      )
      create(
        :llm_event,
        account: account,
        provider: 'openrouter',
        event_name: 'llm.tool.failed',
        tool_failure: true,
        created_at: current_time - 25.minutes
      )
      create(
        :llm_event,
        account: account,
        provider: 'openrouter',
        event_name: 'llm.zero_completion.recovered',
        status: 'recovered',
        created_at: current_time - 20.minutes
      )

      payload = described_class.call(account: account, at: current_time)

      expect(payload[:windows][:today]).to include(
        request_count: 3,
        cached_tokens: 33,
        reasoning_tokens: 21
      )
      expect(payload[:runtime_health]).to include(
        request_count: 3,
        success_count: 2,
        error_count: 1,
        schema_invalid_count: 1,
        tool_failure_count: 1,
        zero_completion_count: 1,
        zero_completion_recovered_count: 1,
        fallback_model_count: 1,
        p50_duration_ms: 500,
        p95_duration_ms: 900
      )
      expect(payload[:runtime_health][:error_rate]).to be > 0
      expect(payload[:key_health]).to include(
        status: 'valid',
        configured: true,
        source: 'management_key',
        credits_status: 'available',
        credits_remaining: 7.25
      )
    end

    def create_usage_event(account:, occurred_at:, **attributes)
      event = create(
        :llm_event,
        account: account,
        provider: 'openrouter',
        event_name: 'llm.chat.complete',
        status: attributes[:status] || 'success',
        error_code: attributes[:error_code],
        created_at: occurred_at
      )

      create(
        :llm_usage_event,
        {
          account: account,
          llm_event: event,
          occurred_at: occurred_at,
          provider: 'openrouter',
          cached_tokens: 11,
          reasoning_tokens: 7
        }.merge(attributes)
      )
    end
  end
end
