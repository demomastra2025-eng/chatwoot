# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::EventsQuery do
  let(:account) { create(:account) }

  describe '#paginated_events' do
    it 'filters events and returns snapshot metadata for the filtered scope' do
      recent_event = create(
        :llm_event,
        account: account,
        feature: 'assistant',
        model: 'gpt-4.1-mini',
        event_name: 'llm.chat.complete',
        assistant_id: 42,
        project_case_id: 'crm.lookup_tool',
        error_code: 'provider_unavailable',
        runtime_mode: 'captain_runtime',
        status: 'completed',
        created_at: 2.hours.ago
      )
      create(
        :llm_event,
        account: account,
        feature: 'copilot',
        model: 'claude-3-5-sonnet',
        event_name: 'llm.tool.complete',
        assistant_id: 88,
        runtime_mode: 'copilot_runtime',
        status: 'completed',
        created_at: 1.hour.ago
      )

      query = described_class.new(
        scope: LlmEvent.for_account(account.id),
        params: {
          feature: 'assistant',
          model: 'gpt-4.1-mini',
          assistant_id: 42,
          project_case_id: ' crm.lookup_tool ',
          error_code: ' provider_unavailable ',
          runtime_mode: 'captain_runtime',
          page: 1,
          per_page: 10
        }
      )

      expect(query.paginated_events).to contain_exactly(recent_event)
      expect(query.snapshot).to include(
        total_events: 1,
        request_count: 1,
        by_model: { 'gpt-4.1-mini' => 1 }
      )
      expect(query.meta).to include(
        count: 1,
        current_page: 1,
        per_page: 10,
        applied_filters: include(
          feature: 'assistant',
          model: 'gpt-4.1-mini',
          assistant_id: 42,
          project_case_id: 'crm.lookup_tool',
          error_code: 'provider_unavailable',
          runtime_mode: 'captain_runtime'
        )
      )
    end

    it 'builds a release gate report against the filtered scope' do
      10.times do |index|
        create(
          :llm_event,
          account: account,
          feature: 'assistant',
          assistant_id: 42,
          created_at: 2.hours.ago + index.minutes
        )
      end

      query = described_class.new(
        scope: LlmEvent.for_account(account.id),
        params: {
          feature: 'assistant',
          assistant_id: 42
        }
      )

      report = query.release_gate(account: account)

      expect(report[:current_period][:metrics]).to include(request_count: 10)
      expect(report[:status]).to eq('pass')
    end

    it 'caps per_page to the configured maximum' do
      query = described_class.new(params: { per_page: 999 })

      expect(query.send(:per_page)).to eq(described_class::MAX_PER_PAGE)
    end

    it 'supports filtering by semantic event flags' do
      flagged_event = create(
        :llm_event,
        account: account,
        feature: 'assistant',
        event_name: 'llm.tool.complete',
        tool_failure: true,
        error: true
      )
      create(:llm_event, account: account, feature: 'assistant', event_name: 'llm.chat.complete')

      query = described_class.new(
        scope: LlmEvent.for_account(account.id),
        params: { flag: 'tool_failure' }
      )

      expect(query.paginated_events).to contain_exactly(flagged_event)
      expect(query.meta).to include(
        applied_filters: include(flag: 'tool_failure')
      )
    end

    it 'supports filtering by session identifier' do
      traced_event = create(
        :llm_event,
        account: account,
        session_id: 'trace-session-1',
        event_name: 'llm.chat.complete'
      )
      create(:llm_event, account: account, session_id: 'trace-session-2')

      query = described_class.new(
        scope: LlmEvent.for_account(account.id),
        params: { session_id: 'trace-session-1' }
      )

      expect(query.paginated_events).to contain_exactly(traced_event)
      expect(query.meta).to include(
        applied_filters: include(session_id: 'trace-session-1')
      )
    end

    it 'supports filtering by trace identifier' do
      traced_event = create(
        :llm_event,
        account: account,
        event_name: 'llm.chat.complete',
        trace_id: 'trace-1',
        payload: { trace_id: 'trace-1' }
      )
      create(
        :llm_event,
        account: account,
        event_name: 'llm.chat.complete',
        trace_id: 'trace-2',
        payload: { trace_id: 'trace-2' }
      )

      query = described_class.new(
        scope: LlmEvent.for_account(account.id),
        params: { trace_id: 'trace-1' }
      )

      expect(query.paginated_events).to contain_exactly(traced_event)
      expect(query.meta).to include(
        applied_filters: include(trace_id: 'trace-1')
      )
    end

    it 'builds time-series points for the filtered scope' do
      create(
        :llm_event,
        account: account,
        event_name: 'llm.chat.complete',
        error: false,
        duration_ms: 120,
        estimated_cost: 0.0012,
        created_at: 3.hours.ago
      )
      create(
        :llm_event,
        account: account,
        event_name: 'llm.chat.complete',
        error: true,
        duration_ms: 240,
        estimated_cost: 0.0024,
        created_at: 2.hours.ago
      )

      query = described_class.new(
        scope: LlmEvent.for_account(account.id),
        params: {
          since: 4.hours.ago.to_i.to_s,
          until: 1.hour.ago.to_i.to_s
        },
        date_range: 4.hours.ago..1.hour.ago
      )

      time_series = query.time_series

      expect(time_series[:bucket]).to eq('hour')
      expect(time_series[:points]).not_to be_empty
      expect(time_series[:points].sum { |point| point[:request_count] }).to eq(2)
      expect(time_series[:points].sum { |point| point[:error_count] }).to eq(1)
      expect(time_series[:points].sum { |point| point[:estimated_cost] }).to eq(0.0036)
      expect(time_series[:points].filter_map { |point| point[:avg_duration_ms] }).to include(120.0, 240.0)
    end
  end
end
