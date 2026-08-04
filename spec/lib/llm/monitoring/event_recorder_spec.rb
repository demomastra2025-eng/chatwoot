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
        project_case_id: nil,
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

    it 'persists flagged guardrail events without raw snippets' do
      described_class.record_notification(
        event_name: 'llm.safety.flagged',
        started_at: Time.current,
        finished_at: Time.current,
        payload: {
          'feature' => 'assistant',
          'stage' => 'tool_results',
          'reason' => 'sensitive_info',
          'rule' => 'bearer_token',
          'action' => 'flag',
          'snippet_hash' => 'a' * 64
        }
      )

      event = LlmEvent.order(:id).last
      expect(event).to have_attributes(
        event_name: 'llm.safety.flagged',
        feature: 'assistant',
        reason: 'sensitive_info',
        blocked: false
      )
      expect(event.payload).to include(
        'stage' => 'tool_results',
        'action' => 'flag',
        'snippet_hash' => 'a' * 64
      )
      expect(event.payload.to_json).not_to include('Bearer')
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

    it 'persists zero-completion recovery events for assistant observability' do
      described_class.record_notification(
        event_name: 'llm.zero_completion.recovered',
        started_at: Time.current,
        finished_at: Time.current,
        payload: {
          'account_id' => account.id,
          'feature' => 'assistant',
          'runtime_mode' => 'captain_runtime',
          'schema_name' => 'Captain::ResponseSchema',
          'status' => 'recovered',
          'reason' => 'Assistant runtime returned a blank response',
          'recovery_kind' => 'finalization_only_retry',
          'completed_tools_count' => 1,
          'completed_tool_names' => ['create_deal']
        }
      )

      event = LlmEvent.order(:id).last
      expect(event).to have_attributes(
        event_name: 'llm.zero_completion.recovered',
        account_id: account.id,
        feature: 'assistant',
        runtime_mode: 'captain_runtime',
        schema_name: 'Captain::ResponseSchema',
        reason: 'Assistant runtime returned a blank response',
        status: 'recovered'
      )
      expect(event.payload).to include(
        'recovery_kind' => 'finalization_only_retry',
        'completed_tools_count' => 1,
        'completed_tool_names' => ['create_deal']
      )
    end

    it 'persists context transform events for OpenRouter troubleshooting' do
      described_class.record_notification(
        event_name: 'llm.context_transform.applied',
        started_at: Time.current,
        finished_at: Time.current,
        payload: {
          'account_id' => account.id,
          'feature' => 'assistant',
          'model' => 'openai/gpt-5.4-mini',
          'provider' => 'openrouter',
          'status' => 'applied',
          'openrouter_context_transform_status' => 'applied',
          'openrouter_context_transform_reason' => 'estimated_tokens_exceed_soft_context_limit',
          'openrouter_context_estimated_tokens' => 90,
          'openrouter_context_limit' => 100
        }
      )

      event = LlmEvent.order(:id).last
      expect(event).to have_attributes(
        event_name: 'llm.context_transform.applied',
        account_id: account.id,
        feature: 'assistant',
        provider: 'openrouter',
        model: 'openai/gpt-5.4-mini',
        status: 'applied'
      )
      expect(event.payload).to include(
        'openrouter_context_transform_status' => 'applied',
        'openrouter_context_transform_reason' => 'estimated_tokens_exceed_soft_context_limit',
        'openrouter_context_estimated_tokens' => 90,
        'openrouter_context_limit' => 100
      )
    end

    it 'persists request compile timing as a local performance metric' do
      described_class.record_notification(
        event_name: 'llm.request.compile',
        started_at: Time.zone.parse('2026-04-10 10:00:00'),
        finished_at: Time.zone.parse('2026-04-10 10:00:00.045'),
        payload: {
          'account_id' => account.id,
          'feature' => 'captain_agent',
          'provider' => 'openrouter',
          'model' => 'openai/gpt-5.4-mini',
          'status' => 'success',
          'openrouter_require_parameters' => true
        }
      )

      event = LlmEvent.order(:id).last
      expect(event).to have_attributes(
        event_name: 'llm.request.compile',
        account_id: account.id,
        feature: 'captain_agent',
        provider: 'openrouter',
        model: 'openai/gpt-5.4-mini',
        status: 'success',
        duration_ms: 45
      )
      expect(event.payload).to include('openrouter_require_parameters' => true)
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
          'project_case_id' => 'crm.lookup_tool',
          'error' => true,
          'error_code' => 'timeout',
          'queue_wait_ms' => '42',
          'thinking_tokens' => '12'
        }
      )

      event = LlmEvent.order(:id).last
      expect(event).to have_attributes(
        project_case_id: 'crm.lookup_tool',
        error_code: 'timeout',
        queue_wait_ms: 42,
        thinking_tokens: 12,
        tool_calls_count: 1,
        payload_truncated: false
      )
      expect(event.payload).to include(
        'payload_budget_bytes' => Llm::Monitoring::EventRecorder::PERSISTED_PAYLOAD_MAX_BYTES,
        'tool_calls_count' => 1,
        'error_code' => 'timeout',
        'queue_wait_ms' => 42,
        'thinking_tokens' => 12
      )
      expect(event.payload['payload_bytes']).to be_positive
    end

    it 'persists lightweight tool requests separately from tool executions' do
      described_class.record_notification(
        event_name: 'llm.tool.requested',
        started_at: Time.current,
        finished_at: Time.current,
        payload: {
          'account_id' => account.id,
          'feature' => 'assistant',
          'runtime_mode' => 'captain_runtime',
          'tool_name' => 'search_articles',
          'arguments_keys' => %w[query category_id],
          'arguments_size' => 48
        }
      )

      event = LlmEvent.order(:id).last
      expect(event).to have_attributes(
        event_name: 'llm.tool.requested',
        tool_name: 'search_articles',
        tool_calls_count: nil,
        tool_failure: false
      )
      expect(event.payload).to include(
        'arguments_keys' => %w[query category_id],
        'arguments_size' => 48
      )
    end

    it 'bounds large sanitized payloads while preserving RCA columns and essential summary fields' do
      described_class.record_notification(
        event_name: 'llm.chat.complete',
        started_at: Time.current,
        finished_at: Time.current,
        payload: {
          'account_id' => account.id,
          'feature' => 'assistant',
          'project_case_id' => 'provider.failure',
          'model' => 'gpt-4.1-mini',
          'canonical_event_name' => 'x' * 2_500,
          'event_name_alias' => 'x' * 2_500,
          'error_class' => 'x' * 2_500,
          'failure_mode' => 'x' * 2_500,
          'status' => 'failed',
          'error_code' => 'provider_unavailable',
          'details' => Array.new(30) { |index| { "key_#{index}" => 'x' * 2_000 } }
        }
      )

      event = LlmEvent.order(:id).last
      expect(event).to have_attributes(
        project_case_id: 'provider.failure',
        error_code: 'provider_unavailable',
        payload_truncated: true
      )
      expect(event.payload.to_json.bytesize).to be <= Llm::Monitoring::EventRecorder::PERSISTED_PAYLOAD_MAX_BYTES
      expect(event.payload).to include(
        'payload_truncated' => true,
        'payload_bytes' => be > Llm::Monitoring::EventRecorder::PERSISTED_PAYLOAD_MAX_BYTES,
        'payload_budget_bytes' => Llm::Monitoring::EventRecorder::PERSISTED_PAYLOAD_MAX_BYTES
      )
      expect(event.payload).not_to have_key('details')
      expect(event.payload).not_to have_key('error_class')
    end

    it 'enqueues OpenRouter generation metadata enrichment for persisted OpenRouter chat events' do
      expect(Internal::FetchOpenRouterGenerationMetadataJob).to receive(:perform_later) do |event_id, generation_id|
        event = LlmEvent.find(event_id)
        expect(event.provider).to eq('openrouter')
        expect(event.payload['openrouter_generation_id']).to eq('gen-123')
        expect(generation_id).to eq('gen-123')
      end

      described_class.record_notification(
        event_name: 'llm.chat.complete',
        started_at: Time.current,
        finished_at: Time.current,
        payload: {
          'account_id' => account.id,
          'feature' => 'assistant',
          'provider' => 'openrouter',
          'model' => 'openai/gpt-4o',
          'openrouter_generation_id' => 'gen-123'
        }
      )
    end

    it 'mirrors persisted provider events into the local usage ledger' do
      expect do
        described_class.record_notification(
          event_name: 'llm.chat.complete',
          started_at: Time.current,
          finished_at: Time.current,
          payload: {
            'account_id' => account.id,
            'feature' => 'assistant',
            'provider' => 'openrouter',
            'model' => 'openai/gpt-4o',
            'prompt_tokens' => 100,
            'completion_tokens' => 25,
            'thinking_tokens' => 5,
            'openrouter_generation_id' => 'gen-ledger',
            'endpoint_provider' => 'OpenAI'
          }
        )
      end.to change(LlmUsageEvent, :count).by(1)

      usage = LlmUsageEvent.last
      expect(usage).to have_attributes(
        account_id: account.id,
        provider: 'openrouter',
        actual_provider: 'OpenAI',
        requested_model: 'openai/gpt-4o',
        actual_model: 'openai/gpt-4o',
        prompt_tokens: 100,
        completion_tokens: 25,
        reasoning_tokens: 5,
        generation_id: 'gen-ledger'
      )
    end

    it 'persists budget warning events without creating usage ledger rows' do
      expect do
        described_class.record_notification(
          event_name: 'llm.budget.warning',
          started_at: Time.current,
          finished_at: Time.current,
          payload: {
            'account_id' => account.id,
            'feature' => 'captain_agent',
            'provider' => 'openrouter',
            'model' => 'openai/gpt-4o',
            'status' => 'warning',
            'error_code' => Llm::BudgetEvaluator::WARNING_CODE,
            'budget_decision' => { 'reason' => 'daily_budget_warning' }
          }
        )
      end.to change(LlmEvent, :count).by(1).and not_change(LlmUsageEvent, :count)

      event = LlmEvent.order(:id).last
      expect(event).to have_attributes(
        event_name: 'llm.budget.warning',
        account_id: account.id,
        feature: 'captain_agent',
        status: 'warning',
        error_code: Llm::BudgetEvaluator::WARNING_CODE,
        blocked: false,
        error: false
      )
      expect(event.payload['budget_decision']).to include('reason' => 'daily_budget_warning')
    end

    it 'does not enqueue generation metadata enrichment for direct-provider events' do
      expect(Internal::FetchOpenRouterGenerationMetadataJob).not_to receive(:perform_later)

      described_class.record_notification(
        event_name: 'llm.chat.complete',
        started_at: Time.current,
        finished_at: Time.current,
        payload: {
          'account_id' => account.id,
          'feature' => 'assistant',
          'provider' => 'openai',
          'model' => 'gpt-4.1-mini',
          'openrouter_generation_id' => 'gen-123'
        }
      )
    end
  end
end
