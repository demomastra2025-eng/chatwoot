# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::RuntimeHealth do
  describe '#call' do
    let(:account) { create(:account) }
    let(:now) { Time.zone.parse('2026-05-22 12:00:00 UTC') }
    let(:date_range) { (now - 1.hour)..now }

    it 'summarizes runtime health, provider failures, and payload budget without exposing raw payload content' do
      create(
        :llm_event,
        account: account,
        event_name: 'llm.chat.complete',
        provider: 'openai',
        model: 'gpt-4.1-mini',
        status: 'completed',
        created_at: now - 20.minutes
      )
      create(
        :llm_event,
        account: account,
        event_name: 'llm.chat.complete',
        provider: 'openrouter',
        model: 'openrouter/anthropic/claude-sonnet-4',
        status: 'failed',
        error: true,
        error_code: 'provider_unavailable',
        payload: { 'prompt' => 'private customer prompt must not leak' },
        created_at: now - 10.minutes
      )
      create(
        :llm_event,
        account: account,
        event_name: 'llm.tool.complete',
        provider: 'openrouter',
        model: 'openrouter/anthropic/claude-sonnet-4',
        payload_truncated: true,
        payload: { 'messages' => ['private customer message must not leak'] },
        created_at: now - 5.minutes
      )

      with_modified_env('LLM_EVENT_OTEL_EXPORT_ENABLED' => 'true', 'LLM_EVENT_OTEL_SAMPLE_RATE' => 'not-a-number') do
        allow(ChatwootApp).to receive(:otel_enabled?).and_return(true)

        health = described_class.new(
          account: account,
          scope: account.llm_events,
          date_range: date_range,
          now: now
        ).call

        expect(health).to include(
          status: 'critical',
          account_id: account.id,
          evaluated_at: now
        )
        expect(health[:checks]).to include(
          include(name: 'event_ingestion', status: 'pass', severity: 'info'),
          include(name: 'provider_failures', status: 'fail', severity: 'critical', actual: 1),
          include(name: 'payload_budget', status: 'warn', severity: 'warning', actual: 1),
          include(name: 'otel_event_export', status: 'warn', severity: 'warning')
        )
        expect(health[:recent_error_codes]).to include('provider_unavailable' => 1)
        expect(health[:top_models]).to include('gpt-4.1-mini' => 1)
        expect(health.to_json).not_to include('private customer prompt', 'private customer message')
      end
    end

    it 'keeps the default scope account-scoped' do
      other_account = create(:account)
      create(:llm_event, account: account, model: 'gpt-4.1-mini', created_at: now - 10.minutes)
      create(
        :llm_event,
        account: other_account,
        model: 'openrouter/anthropic/claude-sonnet-4',
        error: true,
        error_code: 'provider_unavailable',
        created_at: now - 5.minutes
      )

      health = described_class.new(account: account, date_range: date_range, now: now).call

      expect(health).to include(status: 'ok', account_id: account.id)
      expect(health[:top_models]).to eq('gpt-4.1-mini' => 1)
      expect(health[:recent_error_codes]).to eq({})
    end
  end
end
