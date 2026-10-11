require 'rails_helper'

RSpec.describe 'Captain channel matrix', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:captain_assistant, account: account) }
  let(:specialist) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/captain/channel_matrix" }
  let(:headers) { admin.create_new_auth_token }

  it 'returns text channels and effective external agents' do
    create(:captain_inbox, inbox: inbox, captain_assistant: agent)
    specialist.update!(channel_scope: 'selected')
    specialist.agent_channels.create!(account: account, inbox: inbox)
    internal = create(:captain_assistant, account: account, usage_mode: 'internal_assistant')

    get path, headers: headers

    expect(response).to have_http_status(:success)
    body = JSON.parse(response.body)
    channel = body.fetch('channels').find { |item| item['inbox_id'] == inbox.id }
    expect(channel).to include('ai_enabled' => true, 'main_assistant_id' => agent.id,
                               'assistant_ids' => [agent.id, specialist.id].sort)
    expect(body.fetch('assistants').pluck('id')).not_to include(internal.id)
  end

  it 'excludes voice channels and rejects attempts to change them' do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: 'APtest'))
    voice = create(:inbox, account: account, channel: build(:channel_voice, account: account))
    create(:captain_inbox, inbox: voice, captain_assistant: agent)

    get path, headers: headers
    expect(JSON.parse(response.body).fetch('channels').pluck('inbox_id')).not_to include(voice.id)

    patch path, headers: headers, as: :json, params: { channels: [{ inbox_id: voice.id, ai_enabled: false }] }
    expect(response).to have_http_status(:unprocessable_content)
    expect(voice.reload.captain_inbox).to be_ai_enabled
  end

  it 'applies selected memberships, default and channel settings atomically' do
    patch path, headers: headers, as: :json, params: {
      default_main_assistant_id: agent.id,
      assistants: [{ id: agent.id, channel_scope: 'selected', inbox_ids: [inbox.id] }],
      channels: [{ inbox_id: inbox.id, ai_enabled: true, main_assistant_id: agent.id, auto_reply_mode: 'working_hours' }]
    }

    expect(response).to have_http_status(:success)
    expect(account.reload.captain_default_assistant_id).to eq(agent.id)
    expect(inbox.reload.captain_inbox).to have_attributes(ai_enabled: true, captain_assistant_id: agent.id,
                                                          auto_reply_mode: 'working_hours')
    expect(agent.reload.selected_inbox_ids).to eq([inbox.id])
  end

  it 'rolls back all changes when a main agent is outside the channel' do
    patch path, headers: headers, as: :json, params: {
      default_main_assistant_id: agent.id,
      assistants: [{ id: agent.id, channel_scope: 'selected', inbox_ids: [] }],
      channels: [{ inbox_id: inbox.id, ai_enabled: true, main_assistant_id: agent.id }]
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body).dig('errors', 0)).to include('code' => 'MAIN_AGENT_NOT_MEMBER', 'inbox_id' => inbox.id)
    expect(account.reload.captain_default_assistant_id).to be_nil
    expect(inbox.reload.captain_inbox).to be_nil
    expect(agent.reload.channel_scope).to eq('all')
  end

  it 'rolls back membership when saving the channel fails after validation' do
    invalid_link = CaptainInbox.new
    invalid_link.errors.add(:base, 'Unavailable')
    allow(CaptainInbox).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid_link))

    patch path, headers: headers, as: :json, params: {
      assistants: [{ id: agent.id, channel_scope: 'selected', inbox_ids: [inbox.id] }],
      channels: [{ inbox_id: inbox.id, ai_enabled: true, main_assistant_id: agent.id }]
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body).dig('errors', 0, 'code')).to eq('INVALID_STATE')
    expect(agent.reload.channel_scope).to eq('all')
    expect(agent.selected_inbox_ids).to be_empty
  end

  it 'rejects an inactive default and a missing main agent' do
    agent.update!(active: false)
    patch path, headers: headers, as: :json, params: { default_main_assistant_id: agent.id }
    expect(JSON.parse(response.body).fetch('errors').pluck('code')).to include('INVALID_DEFAULT')

    patch path, headers: headers, as: :json, params: { channels: [{ inbox_id: inbox.id, ai_enabled: true }] }
    expect(JSON.parse(response.body).fetch('errors').pluck('code')).to include('MAIN_AGENT_REQUIRED')

    patch path, headers: headers, as: :json,
                params: { channels: [{ inbox_id: inbox.id, ai_enabled: true, main_assistant_id: agent.id }] }
    expect(JSON.parse(response.body).fetch('errors').pluck('code')).to include('MAIN_AGENT_INACTIVE')
  end

  it 'allows only administrators to read or update the matrix' do
    member = create(:user, account: account, role: :agent)
    get path, headers: member.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
    patch path, headers: member.create_new_auth_token, as: :json, params: { default_main_assistant_id: agent.id }
    expect(response).to have_http_status(:unauthorized)
    expect(account.reload.captain_default_assistant_id).to be_nil
  end
end
