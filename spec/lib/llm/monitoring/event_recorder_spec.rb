# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::EventRecorder do
  describe '.record_notification' do
    let(:account) { create(:account) }

    it 'persists summarized chat completion events with derived monitoring fields' do
      allow(Llm::Models).to receive(:credit_multiplier_for).with('gpt-4.1-mini').and_return(1)
      allow(Llm::Models).to receive(:estimated_text_cost).with(
        'gpt-4.1-mini',
        input_tokens: 120,
        output_tokens: 40
      ).and_return(0.00012)

      expect do
        described_class.record_notification(
          event_name: 'llm.chat.complete',
          started_at: Time.zone.parse('2026-04-10 10:00:00'),
          finished_at: Time.zone.parse('2026-04-10 10:00:01'),
          payload: {
            'account_id' => account.id,
            'feature' => 'assistant',
            'runtime_mode' => 'captain_runtime',
            'model' => 'gpt-4.1-mini',
            'request_id' => 'request-123',
            'trace_id' => 'trace-123',
            'prompt_tokens' => 120,
            'completion_tokens' => 40,
            'schema_name' => 'Captain::ResponseSchema'
          }
        )
      end.to change(LlmEvent, :count).by(1)

      event = LlmEvent.order(:id).last
      expect(event).to have_attributes(
        event_name: 'llm.chat.complete',
        account_id: account.id,
        feature: 'assistant',
        runtime_mode: 'captain_runtime',
        provider: 'openai',
        model: 'gpt-4.1-mini',
        request_id: 'request-123',
        trace_id: 'trace-123',
        total_tokens: 160,
        duration_ms: 1000,
        credit_multiplier: 1
      )
      expect(event.estimated_cost.to_f).to eq(0.00012)
      expect(event.payload).not_to have_key('request_id')
      expect(event.payload).not_to have_key('trace_id')
      expect(event.payload['payload_bytes']).to be_positive
    end

    it 'persists moderation skip and blocking flags' do
      described_class.record_notification(
        event_name: 'llm.moderation.unavailable',
        started_at: Time.current,
        finished_at: Time.current,
        payload: {
          'feature' => 'assistant',
          'failure_mode' => 'fail_open',
          'reason' => 'provider_not_configured'
        }
      )

      event = LlmEvent.order(:id).last
      expect(event.moderation_skipped).to be(true)
      expect(event.error).to be(true)
      expect(event.reason).to eq('provider_not_configured')
    end

    it 'persists runtime retry events for blank-response recovery' do
      described_class.record_notification(
        event_name: 'llm.run.retry',
        started_at: Time.current,
        finished_at: Time.current,
        payload: {
          'account_id' => account.id,
          'feature' => 'assistant',
          'runtime_mode' => 'captain_runtime',
          'reason' => 'blank_response',
          'status' => 'retrying',
          'error' => true,
          'attempt' => 1,
          'max_attempts' => 1
        }
      )

      event = LlmEvent.order(:id).last
      expect(event).to have_attributes(
        event_name: 'llm.run.retry',
        account_id: account.id,
        feature: 'assistant',
        runtime_mode: 'captain_runtime',
        reason: 'blank_response',
        status: 'retrying',
        error: true
      )
      expect(event.payload).to include('attempt' => 1, 'max_attempts' => 1, 'retry_count' => 1)
    end

    it 'sanitizes persisted payload details before storing them in llm_events' do
      described_class.record_notification(
        event_name: 'llm.chat.complete',
        started_at: Time.current,
        finished_at: Time.current,
        payload: {
          'account_id' => account.id,
          'feature' => 'assistant',
          'model' => 'gpt-4.1-mini',
          'authorization' => 'Bearer top-secret',
          'prompt' => 'private customer request',
          'messages' => [{ 'role' => 'user', 'content' => 'private message' }],
          'details' => {
            'api_key' => 'super-secret',
            'body' => 'x' * 2_500
          }
        }
      )

      event = LlmEvent.order(:id).last
      expect(event.payload['authorization']).to eq('[REDACTED]')
      expect(event.payload['prompt']).to eq('[REDACTED]')
      expect(event.payload['messages']).to eq('[REDACTED]')
      expect(event.payload.dig('details', 'api_key')).to eq('[REDACTED]')
      expect(event.payload.dig('details', 'body')).to end_with('...[TRUNCATED]')
    end

    it 'records compact RCA counters in the sanitized summary payload' do
      described_class.record_notification(
        event_name: 'llm.tool.complete',
        started_at: Time.current,
        finished_at: Time.current,
        payload: {
          'account_id' => account.id,
          'feature' => 'assistant',
          'tool_name' => 'lookup_contact',
          'error' => true,
          'error_code' => 'timeout',
          'queue_wait_ms' => '42',
          'thinking_tokens' => '12'
        }
      )

      event = LlmEvent.order(:id).last
      expect(event.payload).to include(
        'tool_calls_count' => 1,
        'error_code' => 'timeout',
        'queue_wait_ms' => 42,
        'thinking_tokens' => 12
      )
      expect(event.payload['payload_bytes']).to be_positive
    end
  end
end
