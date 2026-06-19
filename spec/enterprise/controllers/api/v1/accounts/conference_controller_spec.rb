require 'rails_helper'

RSpec.describe Api::V1::Accounts::ConferenceController, type: :request do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, account: account) }
  let(:voice_inbox) { voice_channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: voice_inbox, identifier: nil) }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:agent) { create(:user, account: account, role: :agent) }

  let(:webhook_service) { instance_double(Twilio::VoiceWebhookSetupService, perform: true) }
  let(:voice_grant) { instance_double(Twilio::JWT::AccessToken::VoiceGrant) }
  let(:conference_service) do
    instance_double(
      Voice::Provider::Twilio::ConferenceService,
      ensure_conference_sid: 'CF123',
      mark_agent_joined: true,
      end_conference: true
    )
  end

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new).and_return(webhook_service)
    allow(Twilio::JWT::AccessToken::VoiceGrant).to receive(:new).and_return(voice_grant)
    allow(voice_grant).to receive(:outgoing_application_sid=)
    allow(voice_grant).to receive(:outgoing_application_params=)
    allow(voice_grant).to receive(:incoming_allow=)
    allow(Voice::Provider::Twilio::ConferenceService).to receive(:new).and_return(conference_service)
  end

  describe 'GET /conference/token' do
    context 'when unauthenticated' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}/conference/token"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated agent with inbox access' do
      before { create(:inbox_member, inbox: voice_inbox, user: agent) }

      it 'returns token payload' do
        fake_token = instance_double(Twilio::JWT::AccessToken, to_jwt: 'jwt-token', add_grant: nil)
        allow(Twilio::JWT::AccessToken).to receive(:new).and_return(fake_token)

        get "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}/conference/token",
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body['provider']).to eq('twilio')
        expect(body['token']).to eq('jwt-token')
        expect(body['account_id']).to eq(account.id)
        expect(body['inbox_id']).to eq(voice_inbox.id)
      end
    end

    context 'when authenticated agent requests a WhatsApp calling inbox token' do
      let(:whatsapp_channel) do
        create(
          :channel_whatsapp,
          account: account,
          provider: 'whatsapp_cloud',
          provider_config: {
            'api_key' => 'test_key',
            'phone_number_id' => '123456789',
            'business_account_id' => '123456789',
            'source' => 'embedded_signup',
            'calling_enabled' => true
          },
          sync_templates: false,
          validate_provider_config: false
        )
      end
      let(:whatsapp_inbox) { whatsapp_channel.inbox }

      before do
        account.enable_features!('whatsapp_call')
        create(:inbox_member, inbox: whatsapp_inbox, user: agent)
        create(
          :telephony_agent_binding,
          account: account,
          user: agent,
          provider: 'fonoster',
          agent_ref: 'agent-1001',
          agent_aor: 'sip:1001@operator.test'
        )
      end

      it 'uses the Fonoster webphone token path instead of the Twilio conference token path' do
        expect(Voice::Provider::Twilio::TokenService).not_to receive(:new)

        with_modified_env(
          TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
          TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
        ) do
          stub_request(:post, 'https://bridge.example/telephony/webphone/token')
            .with(
              body: hash_including(
                agent_ref: 'agent-1001',
                agent_aor: 'sip:1001@operator.test',
                inbox_id: whatsapp_inbox.id
              ),
              headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s }
            )
            .to_return(
              status: 200,
              body: {
                token: 'test-token',
                username: '1001',
                domain: 'operator.test',
                signalingServer: 'wss://bridge.test/ws',
                targetAor: 'sip:1001@operator.test'
              }.to_json,
              headers: { 'Content-Type' => 'application/json' }
            )

          get "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/conference/token",
              headers: agent.create_new_auth_token
        end

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body['provider']).to eq('fonoster')
        expect(body['calling_supported']).to be(true)
        expect(body['agent_ref']).to eq('agent-1001')
      end
    end

    context 'when authenticated agent requests an Asterisk analog external extension token' do
      let(:voice_channel) do
        create(
          :channel_voice,
          :fonoster,
          account: account,
          provider_config: {
            'provider_kind' => 'asterisk_analog',
            'number_ref' => SecureRandom.uuid,
            'app_ref' => SecureRandom.uuid,
            'trunk_ref' => SecureRandom.uuid,
            'routing_mode' => 'operator',
            'operator_agent_aor' => 'sip:9098@10.66.66.2'
          }
        )
      end

      before do
        create(:inbox_member, inbox: voice_inbox, user: agent)
        create(
          :telephony_sip_profile,
          account: account,
          inbox: voice_inbox,
          user: agent,
          internal_extension: '9098',
          agent_ref: 'profile-530-9098',
          fonoster_agent_ref: 'profile-530-9098',
          agent_aor: 'sip:9098@10.66.66.2',
          availability_mode: 'external_extension'
        )
      end

      it 'does not ask the bridge for a browser webphone token' do
        token_request = stub_request(:post, 'https://bridge.example/telephony/webphone/token')

        with_modified_env(
          TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
          TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
        ) do
          get "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}/conference/token",
              headers: agent.create_new_auth_token
        end

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body['provider']).to eq('fonoster')
        expect(body['calling_supported']).to be(false)
        expect(body['browser_join_supported']).to be(false)
        expect(body['reason']).to eq('provider_managed_external_extension')
        expect(body['agent_ref']).to eq('profile-530-9098')
        expect(token_request).not_to have_been_requested
      end
    end
  end

  describe 'POST /conference' do
    context 'when unauthenticated' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}/conference"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated agent with inbox access' do
      before { create(:inbox_member, inbox: voice_inbox, user: agent) }

      it 'creates conference and sets identifier' do
        post "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}/conference",
             headers: agent.create_new_auth_token,
             params: { conversation_id: conversation.display_id, call_sid: 'CALL123' }

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body['conference_sid']).to be_present
        conversation.reload
        expect(conversation.identifier).to eq('CALL123')
        expect(conference_service).to have_received(:ensure_conference_sid)
        expect(conference_service).to have_received(:mark_agent_joined)
      end

      it 'does not allow accessing conversations from inboxes without access' do
        other_inbox = create(:inbox, account: account)
        other_conversation = create(:conversation, account: account, inbox: other_inbox, identifier: nil)

        post "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}/conference",
             headers: agent.create_new_auth_token,
             params: { conversation_id: other_conversation.display_id, call_sid: 'CALL123' }

        expect(response).to have_http_status(:not_found)
        other_conversation.reload
        expect(other_conversation.identifier).to be_nil
      end

      it 'returns conflict when call_sid missing' do
        post "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}/conference",
             headers: agent.create_new_auth_token,
             params: { conversation_id: conversation.display_id }

        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context 'when the voice inbox uses fonoster' do
      let(:voice_channel) { create(:channel_voice, :fonoster, account: account) }

      before { create(:inbox_member, inbox: voice_inbox, user: agent) }

      it 'returns a non-browser join payload and sets the identifier' do
        post "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}/conference",
             headers: agent.create_new_auth_token,
             params: { conversation_id: conversation.display_id, call_sid: 'CALL123' }

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body['provider']).to eq('fonoster')
        expect(body['join_supported']).to eq(false)
        expect(body['using_webrtc']).to eq(false)
        expect(body['call_ref']).to eq('CALL123')
        expect(conference_service).not_to have_received(:ensure_conference_sid)
        expect(conversation.reload.identifier).to eq('CALL123')
      end
    end
  end

  describe 'DELETE /conference' do
    context 'when unauthenticated' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}/conference"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated agent with inbox access' do
      before { create(:inbox_member, inbox: voice_inbox, user: agent) }

      it 'ends conference and returns success' do
        delete "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}/conference",
               headers: agent.create_new_auth_token,
               params: { conversation_id: conversation.display_id }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['id']).to eq(conversation.display_id)
        expect(conference_service).to have_received(:end_conference)
      end

      it 'does not allow ending conferences for conversations from inboxes without access' do
        other_inbox = create(:inbox, account: account)
        other_conversation = create(:conversation, account: account, inbox: other_inbox, identifier: nil)

        delete "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}/conference",
               headers: agent.create_new_auth_token,
               params: { conversation_id: other_conversation.display_id }

        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when the voice inbox uses fonoster' do
      let(:voice_channel) { create(:channel_voice, :fonoster, account: account) }

      before { create(:inbox_member, inbox: voice_inbox, user: agent) }

      it 'returns a lightweight success payload without ending a browser conference' do
        delete "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}/conference",
               headers: agent.create_new_auth_token,
               params: { conversation_id: conversation.display_id }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['provider']).to eq('fonoster')
        expect(conference_service).not_to have_received(:end_conference)
      end
    end
  end
end
