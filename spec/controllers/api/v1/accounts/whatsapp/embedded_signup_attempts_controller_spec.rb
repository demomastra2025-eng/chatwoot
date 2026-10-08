require 'rails_helper'

RSpec.describe 'WhatsApp Embedded Signup attempts API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:nonce) { SecureRandom.urlsafe_base64(24) }
  let(:attempt_url) { "/api/v1/accounts/#{account.id}/whatsapp/embedded_signup_attempt" }
  let(:authorization_url) { "/api/v1/accounts/#{account.id}/whatsapp/authorization" }

  def attempt_for(user = administrator)
    Whatsapp::EmbeddedSignupAttempt.new(account: account, user: user, nonce: nonce)
  end

  describe 'POST /whatsapp/embedded_signup_attempt' do
    it 'registers a pending attempt and logs only a digest reference' do
      allow(Rails.logger).to receive(:info)

      post attempt_url, params: { signup_nonce: nonce, signup_type: 'coexistence' },
                        headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq('status' => 'pending', 'signup_type' => 'coexistence')
      expect(Rails.logger).to have_received(:info).with(a_string_including('"phase":"started"'))
      expect(Rails.logger).not_to have_received(:info).with(a_string_including(nonce))
    end

    it 'rejects a malformed nonce' do
      post attempt_url, params: { signup_nonce: 'short' }, headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error_code']).to eq('invalid_signup_attempt')
    end

    it 'forbids agents' do
      agent = create(:user, account: account, role: :agent)

      post attempt_url, params: { signup_nonce: nonce }, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'requires authentication' do
      post attempt_url, params: { signup_nonce: nonce }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'POST /whatsapp/embedded_signup_attempt/status' do
    it 'returns the outcome of the attempt to the user who started it' do
      inbox = create(:inbox, account: account)
      attempt_for.claim(signup_type: 'standard')
      attempt_for.complete!(inbox.id)

      post "#{attempt_url}/status", params: { signup_nonce: nonce }, headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('status' => 'completed', 'signup_type' => 'standard', 'inbox_id' => inbox.id)
    end

    it 'does not reveal another administrator\'s attempt' do
      attempt_for.claim(signup_type: 'standard')
      other_admin = create(:user, account: account, role: :administrator)

      post "#{attempt_url}/status", params: { signup_nonce: nonce }, headers: other_admin.create_new_auth_token, as: :json

      expect(response.parsed_body).to eq('status' => 'unknown')
    end
  end

  describe 'POST /whatsapp/authorization with signup_nonce' do
    let(:whatsapp_channel) { create(:channel_whatsapp, account: account, validate_provider_config: false, sync_templates: false) }
    let!(:inbox) { create(:inbox, account: account, channel: whatsapp_channel) }
    let(:service) { instance_double(Whatsapp::EmbeddedSignupService, perform: whatsapp_channel, waba_source: 'token_scope') }

    before do
      allow(whatsapp_channel).to receive(:inbox).and_return(inbox)
    end

    it 'completes a code-only mobile signup by resolving the WABA on the server' do
      expect(Whatsapp::EmbeddedSignupService).to receive(:new).with(
        account: account,
        params: { code: 'mobile_code', signup_type: 'standard' },
        inbox_id: nil,
        resolve_waba_from_token: true
      ).and_return(service)

      post authorization_url, params: { code: 'mobile_code', signup_type: 'standard', signup_nonce: nonce },
                              headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['id']).to eq(inbox.id)
      expect(attempt_for.client_state).to eq(status: 'completed', signup_type: 'standard', inbox_id: inbox.id)
    end

    it 'keeps using the session-event WABA when the browser sent it' do
      expect(Whatsapp::EmbeddedSignupService).to receive(:new).with(
        account: account,
        params: { code: 'desktop_code', signup_type: 'standard', waba_id: 'waba-1' },
        inbox_id: nil
      ).and_return(service)

      post authorization_url, params: { code: 'desktop_code', signup_type: 'standard', waba_id: 'waba-1', signup_nonce: nonce },
                              headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
    end

    it 'rejects a replayed completion without calling Meta again' do
      allow(Whatsapp::EmbeddedSignupService).to receive(:new).and_return(service)
      headers = administrator.create_new_auth_token
      payload = { code: 'mobile_code', signup_type: 'standard', signup_nonce: nonce }

      post authorization_url, params: payload, headers: headers, as: :json
      post authorization_url, params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['error_code']).to eq('signup_attempt_already_used')
      expect(Whatsapp::EmbeddedSignupService).to have_received(:new).once
    end

    it 'records the failure code so a resumed tab can explain it' do
      allow(Whatsapp::EmbeddedSignupService).to receive(:new).and_return(service)
      allow(service).to receive(:perform)
        .and_raise(Whatsapp::EmbeddedSignupWabaResolver::ResolutionError.new('waba_ambiguous', 'Several WABAs'))

      post authorization_url, params: { code: 'mobile_code', signup_type: 'standard', signup_nonce: nonce },
                              headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error_code']).to eq('waba_ambiguous')
      expect(attempt_for.client_state).to eq(status: 'failed', signup_type: 'standard', error_code: 'waba_ambiguous')
    end

    it 'returns the authorized existing inbox when signup discovers the same connection' do
      allow(Whatsapp::EmbeddedSignupService).to receive(:new).and_return(service)
      allow(service).to receive(:perform)
        .and_raise(Whatsapp::ChannelCreationService::AlreadyConnectedError.new(inbox_id: inbox.id))

      post authorization_url, params: { code: 'mobile_code', signup_type: 'standard', signup_nonce: nonce },
                              headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include('error_code' => 'already_connected', 'inbox_id' => inbox.id)
      expect(attempt_for.client_state).to eq(
        status: 'failed', signup_type: 'standard', error_code: 'already_connected', inbox_id: inbox.id
      )
    end

    it 'does not disclose an inbox id from another account' do
      other_account_inbox = create(:inbox, account: create(:account))
      allow(Whatsapp::EmbeddedSignupService).to receive(:new).and_return(service)
      allow(service).to receive(:perform)
        .and_raise(Whatsapp::ChannelCreationService::AlreadyConnectedError.new(inbox_id: other_account_inbox.id))

      post authorization_url, params: { code: 'mobile_code', signup_type: 'standard', signup_nonce: nonce },
                              headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('error_code' => 'authorization_failed')
      expect(response.parsed_body).not_to have_key('inbox_id')
      expect(attempt_for.client_state).to eq(
        status: 'failed', signup_type: 'standard', error_code: 'authorization_failed'
      )
    end

    it 'rejects a malformed nonce before touching Meta' do
      expect(Whatsapp::EmbeddedSignupService).not_to receive(:new)

      post authorization_url, params: { code: 'mobile_code', signup_nonce: 'bad' },
                              headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error_code']).to eq('invalid_signup_attempt')
    end

    it 'does not log the auth code or the nonce in request parameters' do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      filtered = filter.filter('code' => 'mobile_code', 'signup_nonce' => nonce, 'country_code' => 'KZ')

      expect(filtered).to eq('code' => '[FILTERED]', 'signup_nonce' => '[FILTERED]', 'country_code' => 'KZ')
    end
  end
end
