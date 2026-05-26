# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::PerformanceBudgetSnapshot do
  describe '#call' do
    it 'summarizes per-case performance budgets from persisted indexed event fields' do
      account = create(:account)

      20.times do |index|
        create(
          :llm_event,
          account: account,
          project_case_id: 'support_reply',
          duration_ms: 200 + index,
          queue_wait_ms: 20 + index,
          payload_bytes: 1_000 + index,
          prompt_tokens: 100,
          completion_tokens: 40,
          total_tokens: 140 + index,
          estimated_cost: 0.001,
          retry_count: 0,
          tool_calls_count: 1
        )
      end
      create(
        :llm_event,
        account: account,
        project_case_id: 'support_reply',
        event_name: 'llm.tool.complete',
        duration_ms: nil,
        queue_wait_ms: 10,
        payload_bytes: 900,
        payload_truncated: true,
        total_tokens: nil,
        estimated_cost: 0,
        retry_count: 1,
        tool_calls_count: 2
      )
      create(
        :llm_event,
        account: account,
        project_case_id: 'voice_inbound',
        duration_ms: 9_000,
        queue_wait_ms: 2_500,
        payload_bytes: 40_000,
        total_tokens: 13_000,
        estimated_cost: 0.20,
        error: true
      )
      create(:llm_event, account: account, project_case_id: nil)

      snapshot = described_class.new(
        scope: LlmEvent.for_account(account.id),
        budgets: {
          max_p95_duration_ms: 1_000,
          max_p95_queue_wait_ms: 1_000,
          max_p95_payload_bytes: 10_000,
          max_p95_total_tokens: 5_000,
          max_cost_per_request: 0.05,
          max_error_rate: 0.05
        }
      ).call

      expect(snapshot).to include(
        total_project_cases: 2,
        uncovered_event_count: 1,
        status: 'fail'
      )

      support_case = snapshot[:cases].find { |entry| entry[:project_case_id] == 'support_reply' }
      expect(support_case).to include(
        event_count: 21,
        request_count: 20,
        event_error_count: 0,
        request_error_count: 0,
        status: 'pass'
      )
      expect(support_case[:metrics]).to include(
        payload_truncated_count: 1,
        retry_occurrences: 1,
        tool_call_occurrences: 22,
        request_error_rate: 0.0
      )
      expect(support_case[:checks]).to all(include(status: 'pass'))

      voice_case = snapshot[:cases].find { |entry| entry[:project_case_id] == 'voice_inbound' }
      expect(voice_case).to include(
        event_count: 1,
        request_count: 1,
        event_error_count: 1,
        request_error_count: 1,
        status: 'fail'
      )
      expect(voice_case[:checks]).to include(
        include(name: 'p95_duration_ms', status: 'fail'),
        include(name: 'p95_queue_wait_ms', status: 'fail'),
        include(name: 'p95_payload_bytes', status: 'fail'),
        include(name: 'p95_total_tokens', status: 'fail'),
        include(name: 'avg_cost_per_request', status: 'fail'),
        include(name: 'request_error_rate', status: 'fail')
      )
    end

    it 'does not invent request-level budget metrics for non-chat-only cases' do
      create(
        :llm_event,
        project_case_id: 'tool_only',
        event_name: 'llm.tool.complete',
        error: true,
        duration_ms: nil,
        total_tokens: nil,
        estimated_cost: 0.25,
        payload_bytes: 2048
      )

      snapshot = described_class.new.call
      tool_only_case = snapshot[:cases].find { |entry| entry[:project_case_id] == 'tool_only' }

      expect(tool_only_case).to include(
        request_count: 0,
        event_error_count: 1,
        request_error_count: 0
      )
      expect(tool_only_case[:metrics]).to include(
        avg_cost_per_request: nil,
        request_error_rate: nil,
        p95_duration_ms: nil,
        p95_total_tokens: nil,
        p95_payload_bytes: 2048.0
      )
      expect(tool_only_case[:checks].pluck(:name)).not_to include(
        'avg_cost_per_request',
        'request_error_rate',
        'p95_duration_ms',
        'p95_total_tokens'
      )
    end

    it 'limits reported cases by event volume and marks empty scopes as insufficient data' do
      create_list(:llm_event, 3, project_case_id: 'high_volume')
      create(:llm_event, project_case_id: 'low_volume')

      snapshot = described_class.new(limit: 1).call
      empty_snapshot = described_class.new(scope: LlmEvent.none).call

      expect(snapshot[:cases].map { |entry| entry[:project_case_id] }).to eq(['high_volume'])
      expect(snapshot[:total_project_cases]).to eq(2)
      expect(empty_snapshot).to include(
        total_project_cases: 0,
        uncovered_event_count: 0,
        cases: [],
        status: 'insufficient_data'
      )
    end
  end
end
