# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reports::AiAgentTransfersQuery do
  let(:account) { create(:account, reporting_timezone: 'Europe/Berlin') }
  let(:range) do
    Reports::DateRange.new(account: account, params: { from_date: '2026-10-11', to_date: '2026-10-11' })
  end

  it 'links transfers to a staff handoff in the same request and excludes synthetic events' do
    from = create(:captain_assistant, account: account)
    to = create(:captain_assistant, account: account)
    conversation = create(:conversation, account: account)
    at = Time.iso8601('2026-10-11T12:00:00Z')
    create(:llm_event, account: account, conversation: conversation, event_name: 'captain.agent.transfer',
                       request_id: 'synthetic-request', created_at: at,
                       payload: { 'run_source' => 'live', 'from_agent_id' => from.id, 'to_agent_id' => to.id })
    create(:llm_event, account: account, conversation: conversation, event_name: 'captain.agent.staff_handoff',
                       request_id: 'synthetic-request', created_at: at, payload: { 'run_source' => 'live' })
    create(:llm_event, account: account, conversation: conversation, event_name: 'captain.agent.transfer_guard',
                       created_at: at, payload: { 'run_source' => 'live' })
    create(:llm_event, account: account, conversation: conversation, event_name: 'captain.agent.transfer',
                       created_at: at, payload: { 'run_source' => 'benchmark', 'from_agent_id' => from.id })

    result = described_class.new(account: account, date_range: range).perform

    expect(result[:transfers]).to contain_exactly(
      include(from_agent_id: from.id, to_agent_id: to.id, conversation_id: conversation.id,
              staff_handoff_same_request: true)
    )
    expect(result[:guard_count]).to eq(1)
  end
end
