# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Account AI Agents Reports API', type: :request do
  let(:account) { create(:account, reporting_timezone: 'Europe/Berlin') }
  let(:administrator) { create(:user, :administrator, account: account) }
  let(:headers) { administrator.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/reports/ai_agents" }
  let(:date_params) { { from_date: '2026-03-29', to_date: '2026-03-29' } }

  it 'returns the native report contract with event-time attribution and a durable pending classification' do
    assistant = create(:captain_assistant, account: account)
    conversation = create(:conversation, account: account, created_at: Time.iso8601('2026-01-01T12:00:00Z'))
    event_at = Time.iso8601('2026-03-29T12:00:00Z')
    create(:message, account: account, conversation: conversation, inbox: conversation.inbox, sender: assistant,
                     message_type: :outgoing, private: false, created_at: event_at, skip_runtime_events: true, skip_send_reply: true)
    ConversationStatusTransition.create!(account: account, conversation: conversation, actor: assistant,
                                         from_status: 'pending', to_status: 'resolved', source: 'captain', created_at: event_at)

    get path, params: date_params, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('meta')).to include('timezone' => 'Europe/Berlin', 'assistant_id' => nil)
    payload = response.parsed_body.fetch('payload')
    expect(payload.keys).to contain_exactly('totals', 'series', 'agents', 'agent_breakdown', 'reasons', 'availability')
    expect(payload.fetch('totals')).to include('message_count' => 1, 'conversation_count' => 1, 'completion_count' => 1, 'handoff_count' => 0)
    expect(payload.dig('totals', 'classification_counts', 'pending')).to eq(1)
    expect(payload.fetch('reasons')).to be_empty
    expect(payload.dig('availability', 'latency')).to eq('available' => false, 'reason' => 'native_attribution_unavailable')
  end

  it 'requires report permission before running an aggregation' do
    agent = create(:user)
    create(:account_user, user: agent, account: account, role: :agent)
    expect(Reports::AiAgentsQuery).not_to receive(:new)

    get path, params: date_params, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:forbidden)
  end

  it 'requires authentication' do
    get path, params: date_params, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects users outside the requested account' do
    other_account = create(:account)
    expect(Reports::AiAgentsQuery).not_to receive(:new)

    get "/api/v1/accounts/#{other_account.id}/reports/ai_agents", params: date_params, headers: headers, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns a specific filter error without exposing foreign assistant details' do
    foreign_assistant = create(:captain_assistant)

    get path, params: date_params.merge(assistant_id: foreign_assistant.id), headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq(
      'code' => 'INVALID_REPORT_AGENT', 'error' => 'assistant_id must identify an assistant in this account'
    )
  end

  it 'returns the existing date-range error for invalid dates and excessive intervals' do
    [
      { from_date: '2026-02-30', to_date: '2026-03-01' },
      { from_date: '2026-01-01', to_date: '2026-04-01' }
    ].each do |params|
      get path, params: params, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch('code')).to eq('INVALID_REPORT_RANGE')
    end
  end

  it 'rejects nonscalar assistant filters instead of silently returning all agents' do
    get path, params: date_params.merge(assistant_id: ['1']), headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch('code')).to eq('INVALID_REPORT_AGENT')
  end

  it 'allows an inactive own-account historical agent filter without requiring a channel assignment' do
    assistant = create(:captain_assistant, account: account, active: false)

    get path, params: date_params.merge(assistant_id: assistant.id), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'assistant_id')).to eq(assistant.id)
    expect(response.parsed_body.dig('payload', 'totals', 'outcome_count')).to eq(0)
    expect(response.parsed_body.dig('payload', 'agents')).to include('id' => assistant.id, 'name' => assistant.name, 'active' => false)
  end
end
