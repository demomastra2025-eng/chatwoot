require 'rails_helper'

RSpec.describe 'Workspace Captain channels', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:first_agent) { create(:captain_assistant, account: account) }
  let(:second_agent) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/captain/channel_matrix" }
  let(:headers) { admin.create_new_auth_token }

  it 'lists the text channels and every external agent with its switch and whether it has a card, with no main agent', :aggregate_failures do
    channel = inbox
    first_agent.update!(routing_description: 'Doctors')
    second_agent.update!(active: false)
    internal = create(:captain_assistant, account: account, usage_mode: 'internal_assistant')

    get path, headers: headers

    expect(response).to have_http_status(:success)
    expect(response.parsed_body.keys).to contain_exactly('channels', 'assistants')
    row = response.parsed_body.fetch('channels').find { |item| item['inbox_id'] == channel.id }
    expect(row).to include('ai_enabled' => false)
    expect(row).not_to have_key('assistant_ids')
    assistants = response.parsed_body.fetch('assistants')
    expect(assistants.pluck('id')).to eq([first_agent.id, second_agent.id])
    expect(assistants.pluck('id')).not_to include(internal.id)
    expect(assistants.first).to include('active' => true, 'has_card' => true)
    expect(assistants.second).to include('active' => false, 'has_card' => false)
    expect(assistants.first).not_to include('main', 'is_main')
  end

  it 'switches a channel on and off with no main agent: the row it creates holds the channel settings only' do
    channel = inbox
    first_agent

    patch path, headers: headers, as: :json, params: { channels: [{ inbox_id: channel.id, ai_enabled: true }] }

    expect(response).to have_http_status(:success)
    expect(channel.reload.captain_inbox).to have_attributes(captain_assistant_id: nil, ai_enabled: true)
    expect(response.parsed_body.fetch('channels').find { |item| item['inbox_id'] == channel.id }).to include('ai_enabled' => true)

    patch path, headers: headers, as: :json, params: { channels: [{ inbox_id: channel.id, ai_enabled: false }] }

    expect(response).to have_http_status(:success)
    expect(channel.reload.captain_inbox).to have_attributes(captain_assistant_id: nil, ai_enabled: false)
  end

  it 'keeps the other channels as they are when one switch changes' do
    first_channel = inbox
    second_channel = create(:inbox, account: account)
    create(:captain_inbox, inbox: second_channel, ai_enabled: true)

    patch path, headers: headers, as: :json, params: { channels: [{ inbox_id: first_channel.id, ai_enabled: true }] }

    expect(response).to have_http_status(:success)
    expect(first_channel.reload.captain_inbox).to be_ai_enabled
    expect(second_channel.reload.captain_inbox).to be_ai_enabled
  end

  it 'saves the switches of a workspace where every agent is switched off, and of a workspace with no agent' do
    channel = inbox
    first_agent.update!(active: false)

    patch path, headers: headers, as: :json, params: { channels: [{ inbox_id: channel.id, ai_enabled: true }] }

    expect(response).to have_http_status(:success)
    expect(channel.reload.captain_inbox).to be_ai_enabled
    expect(response.parsed_body.fetch('assistants').pluck('active')).to eq([false])
  end

  it 'leaves a switch-off of a channel that has no row without creating a row' do
    channel = inbox

    patch path, headers: headers, as: :json, params: { channels: [{ inbox_id: channel.id, ai_enabled: false }] }

    expect(response).to have_http_status(:success)
    expect(CaptainInbox.where(inbox_id: channel.id)).not_to exist
  end

  it 'ignores a main agent sent by an old client' do
    channel = inbox

    patch path, headers: headers, as: :json, params: { default_main_assistant_id: first_agent.id }

    expect(response).to have_http_status(:success)
    expect(response.parsed_body).not_to have_key('default_main_assistant_id')
    expect(CaptainInbox.where(inbox_id: channel.id)).not_to exist
    expect(account.reload.settings).not_to have_key('captain_default_assistant_id')
  end

  it 'starts a new text channel with no row, so the AI answers nothing in it until it is switched on' do
    first_agent

    expect(create(:inbox, account: account).captain_inbox).to be_nil
  end

  it 'rejects an unknown channel and a switch that is not true or false' do
    patch path, headers: headers, as: :json, params: { channels: [{ inbox_id: create(:inbox).id, ai_enabled: true }] }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch('errors').pluck('code')).to include('INVALID_CHANNEL')

    patch path, headers: headers, as: :json, params: { channels: [{ inbox_id: inbox.id, ai_enabled: 'yes' }] }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch('errors').pluck('code')).to include('INVALID_AI_ENABLED')
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
    patch path, headers: member.create_new_auth_token, as: :json, params: { channels: [] }
    expect(response).to have_http_status(:unauthorized)
  end
end
