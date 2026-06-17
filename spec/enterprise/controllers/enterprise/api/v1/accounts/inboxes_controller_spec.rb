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

      it 'rejects legacy direct Sipuni voice inbox creation', :aggregate_failures do
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
                     sipuni_user_id: '123456',
                     default_internal_number: '100',
                     integration_secret: 'integration-secret',
                     audio_mode: 'external_softphone'
                   }
                 }
               },
               as: :json
        end.not_to change(Channel::Voice, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to include('attributes' => include('provider'))
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
    end
  end
end
