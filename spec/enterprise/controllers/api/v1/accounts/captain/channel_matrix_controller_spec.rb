require 'rails_helper'

RSpec.describe 'Workspace Captain channels', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:first_agent) { create(:captain_assistant, account: account) }
  let(:second_agent) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/captain/channel_matrix" }
  let(:headers) { admin.create_new_auth_token }

  it 'shows every active external agent on each text channel' do
    channel = inbox
    first_agent
    second_agent.update!(channel_scope: 'selected')
    internal = create(:captain_assistant, account: account, usage_mode: 'internal_assistant')

    get path, headers: headers

    expect(response).to have_http_status(:success)
    row = response.parsed_body.fetch('channels').find { |item| item['inbox_id'] == channel.id }
    expect(row).to include('ai_enabled' => false, 'assistant_ids' => [first_agent.id, second_agent.id].sort)
    expect(response.parsed_body.fetch('assistants').pluck('id')).not_to include(internal.id)
  end

  it 'stars one agent for all text channels while preserving their switches' do
    first_channel = inbox
    second_channel = create(:inbox, account: account)
    first_agent
    second_agent

    patch path, headers: headers, as: :json, params: { default_main_assistant_id: first_agent.id }
    expect(response).to have_http_status(:success)
    expect(first_channel.reload.captain_inbox).not_to be_ai_enabled
    expect(second_channel.reload.captain_inbox).not_to be_ai_enabled

    patch path, headers: headers, as: :json,
                params: { channels: [{ inbox_id: first_channel.id, ai_enabled: true }] }
    expect(response).to have_http_status(:success)

    patch path, headers: headers, as: :json, params: { default_main_assistant_id: second_agent.id }
    expect(response).to have_http_status(:success)
    expect(first_channel.reload.captain_inbox).to have_attributes(captain_assistant_id: second_agent.id, ai_enabled: true)
    expect(second_channel.reload.captain_inbox).to have_attributes(captain_assistant_id: second_agent.id, ai_enabled: false)
  end

  it 'starts a new text channel with AI on when a main agent exists' do
    account.update!(captain_default_assistant_id: first_agent.id)

    expect(create(:inbox, account: account).captain_inbox).to have_attributes(captain_assistant_id: first_agent.id, ai_enabled: true)
  end

  it 'rejects an inactive main agent and a switch without a main agent' do
    channel = inbox
    first_agent.update!(active: false)

    patch path, headers: headers, as: :json, params: { default_main_assistant_id: first_agent.id }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch('errors').pluck('code')).to include('INVALID_DEFAULT')

    patch path, headers: headers, as: :json, params: { channels: [{ inbox_id: channel.id, ai_enabled: true }] }
    expect(response.parsed_body.fetch('errors').pluck('code')).to include('MAIN_AGENT_REQUIRED')
  end

  it 'does not expose voice channels to the text channel editor' do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: 'APtest'))
    voice = create(:inbox, account: account, channel: build(:channel_voice, account: account))
    voice_link = create(:captain_inbox, inbox: voice, captain_assistant: first_agent)

    get path, headers: headers
    expect(response.parsed_body.fetch('channels').pluck('inbox_id')).not_to include(voice.id)
    patch path, headers: headers, as: :json, params: { channels: [{ inbox_id: voice.id, ai_enabled: false }] }
    expect(response).to have_http_status(:unprocessable_content)
    expect(voice_link.reload).to be_ai_enabled
  end

  it 'allows only administrators to read and update routing' do
    member = create(:user, account: account, role: :agent)
    get path, headers: member.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
    patch path, headers: member.create_new_auth_token, as: :json, params: { default_main_assistant_id: first_agent.id }
    expect(response).to have_http_status(:unauthorized)
  end
end
