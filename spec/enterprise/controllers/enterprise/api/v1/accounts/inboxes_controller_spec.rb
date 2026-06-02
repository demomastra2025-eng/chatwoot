require 'rails_helper'

RSpec.describe 'Enterprise Inboxes API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  describe 'POST /api/v1/accounts/{account.id}/inboxes' do
    let(:inbox) { create(:inbox, account: account) }

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:valid_params) do
        { name: 'test', auto_assignment_config: { max_assignment_limit: 10 }, channel: { type: 'web_widget', website_url: 'test.com' } }
      end

      it 'creates a webwidget inbox with auto assignment config' do
        post "/api/v1/accounts/#{account.id}/inboxes",
             headers: admin.create_new_auth_token,
             params: valid_params,
             as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)['auto_assignment_config']['max_assignment_limit']).to eq 10
      end

      it 'creates a voice inbox when administrator' do
        allow(Twilio::VoiceWebhookSetupService).to receive(:new).and_return(instance_double(Twilio::VoiceWebhookSetupService,
                                                                                            perform: "AP#{SecureRandom.hex(16)}"))

        post "/api/v1/accounts/#{account.id}/inboxes",
             headers: admin.create_new_auth_token,
             params: { name: 'Voice Inbox',
                       channel: { type: 'voice', phone_number: '+15551234567',
                                  provider_config: { account_sid: "AC#{SecureRandom.hex(16)}",
                                                     auth_token: SecureRandom.hex(16),
                                                     api_key_sid: SecureRandom.hex(8),
                                                     api_key_secret: SecureRandom.hex(16),
                                                     twiml_app_sid: "AP#{SecureRandom.hex(16)}" } } },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Voice Inbox')
        expect(response.body).to include('+15551234567')
      end

      it 'creates a Sipuni voice inbox and returns a configured webhook url' do
        expect do
          post "/api/v1/accounts/#{account.id}/inboxes",
               headers: admin.create_new_auth_token,
               params: {
                 name: 'Sipuni Voice',
                 channel: {
                   type: 'voice',
                   phone_number: '+77271234567',
                   provider: 'sipuni',
                   provider_config: {
                     account_number: '123456',
                     default_internal_number: '100',
                     integration_secret: 'integration-secret',
                     audio_mode: 'external_softphone'
                   }
                 }
               },
               as: :json
        end.to change(Channel::Voice.where(provider: 'sipuni'), :count).by(1)

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['channel_type']).to eq('Channel::Voice')
        expect(response.parsed_body['provider']).to eq('sipuni')
        expect(response.parsed_body['sipuni_events_webhook_url']).to include('/webhooks/sipuni/voice/')
        expect(response.parsed_body['provider_config']).to include(
          'account_number' => '123456',
          'default_internal_number' => '100',
          'audio_mode' => 'external_softphone'
        )
        expect(response.parsed_body['provider_config']).not_to have_key('webhook_token')
        expect(response.parsed_body['provider_config']).not_to have_key('integration_secret')
        expect(Channel::Voice.find_by!(phone_number: '+77271234567').provider_config_hash.with_indifferent_access[:integration_secret]).to eq(
          'integration-secret'
        )
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/inboxes/:id' do
    let(:inbox) { create(:inbox, account: account, auto_assignment_config: { max_assignment_limit: 5 }) }

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:valid_params) { { name: 'new test inbox', auto_assignment_config: { max_assignment_limit: 10 } } }

      it 'updates inbox with auto assignment config' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              headers: admin.create_new_auth_token,
              params: valid_params,
              as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)['auto_assignment_config']['max_assignment_limit']).to eq 10
      end

      it 'preserves the Sipuni webhook token when updating sanitized provider config' do
        sipuni_channel = create(:channel_voice, :sipuni, account: account)
        sipuni_inbox = sipuni_channel.inbox
        config = sipuni_channel.provider_config_hash.with_indifferent_access
        token = config[:webhook_token]
        integration_secret = config[:integration_secret]

        patch "/api/v1/accounts/#{account.id}/inboxes/#{sipuni_inbox.id}",
              headers: admin.create_new_auth_token,
              params: {
                channel: {
                  provider_config: {
                    account_number: 'updated-account',
                    default_internal_number: '101',
                    audio_mode: 'external_softphone'
                  }
                }
              },
              as: :json

        expect(response).to have_http_status(:success)
        reloaded_config = sipuni_channel.reload.provider_config_hash.with_indifferent_access
        expect(reloaded_config[:webhook_token]).to eq(token)
        expect(reloaded_config[:integration_secret]).to eq(integration_secret)
        expect(response.parsed_body['provider_config']).not_to have_key('webhook_token')
        expect(response.parsed_body['provider_config']).not_to have_key('integration_secret')
      end
    end
  end
end
