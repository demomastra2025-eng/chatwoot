require 'rails_helper'

RSpec.describe 'Telephony Calls API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: '+15551230000') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:contact) { create(:contact, account: account, phone_number: '+15551239999', name: 'Voice Contact') }
  let(:path) { "/api/v1/accounts/#{account.id}/telephony/calls/outbound" }

  before do
    account.enable_features!('channel_voice')
  end

  it 'creates an outbound call through the telephony bridge and persists local call session' do
    voice_inbox.telephony_number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-app-ref'
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/calls/outbound')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret' })
        .with do |request|
          body = JSON.parse(request.body)
          expect(body['from_number_ref']).to eq(voice_inbox.telephony_number_binding.number_ref)
          expect(body['to']).to eq(contact.phone_number)
          expect(body['app_ref']).to eq('ai-app-ref')
          expect(body.dig('metadata', 'chatwoot_inbox_id')).to eq(voice_inbox.id)
          true
        end
        .to_return(
          status: 200,
          body: {
            call_ref: 'call-123',
            status: 'ringing'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post path,
           params: {
             inbox_id: voice_inbox.id,
             contact_id: contact.id
           },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:created)
    expect(response.parsed_body['call_sid']).to eq('call-123')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'call-123')
    expect(call_session.conversation).to be_present
    expect(call_session.contact_id).to eq(contact.id)
    expect(call_session.inbox_id).to eq(voice_inbox.id)
    expect(call_session.number_binding.number_ref).to eq(voice_inbox.telephony_number_binding.number_ref)
    expect(call_session.status).to eq('ringing')
    expect(call_session.direction).to eq('outbound')
    expect(call_session.conversation.identifier).to eq('call-123')
  end
end
