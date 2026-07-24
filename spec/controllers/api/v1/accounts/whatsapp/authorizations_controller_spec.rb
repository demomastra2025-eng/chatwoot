require 'rails_helper'

RSpec.describe 'WhatsApp Authorization API', type: :request do
  let(:account) { create(:account) }

  describe 'POST /api/v1/accounts/{account.id}/whatsapp/authorization' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/whatsapp/authorization"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated administrator' do
      let(:administrator) { create(:user, account: account, role: :administrator) }
      let(:agent) { administrator }

      context 'when authenticated user makes request' do
        it 'returns unprocessable entity when code is missing' do
          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 business_id: 'test_business_id',
                 waba_id: 'test_waba_id'
               },
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body['error']).to include('code')
        end

        it 'accepts the official standard WABA-only completion payload' do
          whatsapp_channel = create(:channel_whatsapp, account: account, validate_provider_config: false, sync_templates: false)
          inbox = create(:inbox, account: account, channel: whatsapp_channel)
          embedded_signup_service = instance_double(Whatsapp::EmbeddedSignupService, perform: whatsapp_channel)

          expect(Whatsapp::EmbeddedSignupService).to receive(:new).with(
            account: account,
            params: { code: 'test_code', waba_id: 'test_waba_id' },
            inbox_id: nil
          ).and_return(embedded_signup_service)
          allow(whatsapp_channel).to receive(:inbox).and_return(inbox)

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 code: 'test_code',
                 waba_id: 'test_waba_id'
               },
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
        end

        it 'returns unprocessable entity when waba_id is missing' do
          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 code: 'test_code',
                 business_id: 'test_business_id'
               },
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body['error']).to include('waba_id')
        end

        it 'creates whatsapp channel successfully' do
          whatsapp_channel = create(:channel_whatsapp, account: account, validate_provider_config: false, sync_templates: false)
          inbox = create(:inbox, account: account, channel: whatsapp_channel)
          embedded_signup_service = instance_double(Whatsapp::EmbeddedSignupService)

          allow(Whatsapp::EmbeddedSignupService).to receive(:new).and_return(embedded_signup_service)
          allow(embedded_signup_service).to receive(:perform).and_return(whatsapp_channel)
          allow(whatsapp_channel).to receive(:inbox).and_return(inbox)

          # Stub webhook setup service to prevent HTTP calls
          webhook_service = instance_double(Whatsapp::WebhookSetupService)
          allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
          allow(webhook_service).to receive(:perform)

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 code: 'test_code',
                 business_id: 'test_business_id',
                 waba_id: 'test_waba_id',
                 phone_number_id: 'test_phone_id'
               },
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
          response_data = response.parsed_body
          expect(response_data['success']).to be true
          expect(response_data['id']).to eq(inbox.id)
          expect(response_data['name']).to eq(inbox.name)
          expect(response_data['channel_type']).to eq('Channel::Whatsapp')
        end

        it 'calls the embedded signup service with correct parameters' do
          whatsapp_channel = create(:channel_whatsapp, account: account, validate_provider_config: false, sync_templates: false)
          inbox = create(:inbox, account: account, channel: whatsapp_channel)
          embedded_signup_service = instance_double(Whatsapp::EmbeddedSignupService)

          expect(Whatsapp::EmbeddedSignupService).to receive(:new).with(
            account: account,
            params: {
              code: 'test_code',
              business_id: 'test_business_id',
              waba_id: 'test_waba_id',
              phone_number_id: 'test_phone_id'
            },
            inbox_id: nil
          ).and_return(embedded_signup_service)

          allow(embedded_signup_service).to receive(:perform).and_return(whatsapp_channel)
          allow(whatsapp_channel).to receive(:inbox).and_return(inbox)
          allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(instance_double(Whatsapp::WebhookSetupService, perform: true))

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 code: 'test_code',
                 business_id: 'test_business_id',
                 waba_id: 'test_waba_id',
                 phone_number_id: 'test_phone_id'
               },
               headers: agent.create_new_auth_token,
               as: :json
        end

        it 'accepts the official coexistence completion payload without business or phone ids' do
          whatsapp_channel = create(:channel_whatsapp, account: account, validate_provider_config: false, sync_templates: false)
          inbox = create(:inbox, account: account, channel: whatsapp_channel)
          embedded_signup_service = instance_double(Whatsapp::EmbeddedSignupService, perform: whatsapp_channel)

          expect(Whatsapp::EmbeddedSignupService).to receive(:new).with(
            account: account,
            params: {
              code: 'coexistence_code',
              waba_id: 'coexistence_waba',
              signup_type: 'coexistence'
            },
            inbox_id: nil
          ).and_return(embedded_signup_service)
          allow(whatsapp_channel).to receive(:inbox).and_return(inbox)

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 code: 'coexistence_code',
                 waba_id: 'coexistence_waba',
                 signup_type: 'coexistence'
               },
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
        end

        it 'returns unprocessable entity when service fails' do
          allow(Whatsapp::EmbeddedSignupService).to receive(:new).and_raise(StandardError, 'Service error')

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 code: 'test_code',
                 business_id: 'test_business_id',
                 waba_id: 'test_waba_id',
                 phone_number_id: 'test_phone_id'
               },
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          response_data = response.parsed_body
          expect(response_data['success']).to be false
          expect(response_data['error'])
            .to eq('WhatsApp authorization failed. Please check the connection details and try again.')
          expect(response_data['error_code']).to eq('authorization_failed')
        end

        it 'sanitizes the authorization code from provider errors and logs' do
          code = 'sensitive-authorization-code'
          allow(Whatsapp::EmbeddedSignupService).to receive(:new)
            .and_raise(StandardError, "Provider rejected access_token=#{code} Bearer #{code}")
          allow(Rails.logger).to receive(:error)

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 code: code,
                 business_id: 'test_business_id',
                 waba_id: 'test_waba_id',
                 phone_number_id: 'test_phone_id'
               },
               headers: agent.create_new_auth_token,
               as: :json

          expect(response.parsed_body['error'])
            .to eq('WhatsApp authorization failed. Please check the connection details and try again.')
          expect(response.parsed_body['error_code']).to eq('authorization_failed')
          expect(response.parsed_body['error']).not_to include(code)
          expect(Rails.logger).not_to have_received(:error).with(include(code))
        end

        it 'logs error when service fails' do
          allow(Whatsapp::EmbeddedSignupService).to receive(:new).and_raise(StandardError, 'Service error')

          expect(Rails.logger).to receive(:error).with(/\[WHATSAPP AUTHORIZATION\] Embedded signup error: Service error/)
          expect(Rails.logger).to receive(:error).with(/authorizations_controller/)

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 code: 'test_code',
                 business_id: 'test_business_id',
                 waba_id: 'test_waba_id',
                 phone_number_id: 'test_phone_id'
               },
               headers: agent.create_new_auth_token,
               as: :json
        end

        it 'handles token exchange errors' do
          allow(Whatsapp::EmbeddedSignupService).to receive(:new)
            .and_raise(StandardError, 'Invalid authorization code')

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 code: 'invalid_code',
                 business_id: 'test_business_id',
                 waba_id: 'test_waba_id',
                 phone_number_id: 'test_phone_id'
               },
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body['error'])
            .to eq('WhatsApp authorization failed. Please check the connection details and try again.')
          expect(response.parsed_body['error_code']).to eq('authorization_failed')
        end

        it 'handles channel already exists error' do
          allow(Whatsapp::EmbeddedSignupService).to receive(:new)
            .and_raise(StandardError, 'Channel already exists')

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 code: 'test_code',
                 business_id: 'test_business_id',
                 waba_id: 'test_waba_id',
                 phone_number_id: 'test_phone_id'
               },
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body['error'])
            .to eq('WhatsApp authorization failed. Please check the connection details and try again.')
          expect(response.parsed_body['error_code']).to eq('authorization_failed')
        end
      end

      context 'when user is not authorized for the account' do
        let(:other_account) { create(:account) }

        it 'returns unauthorized' do
          post "/api/v1/accounts/#{other_account.id}/whatsapp/authorization",
               params: {
                 code: 'test_code',
                 business_id: 'test_business_id',
                 waba_id: 'test_waba_id',
                 phone_number_id: 'test_phone_id'
               },
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unauthorized)
        end
      end

      context 'when user is an administrator' do
        it 'allows channel creation' do
          embedded_signup_service = instance_double(Whatsapp::EmbeddedSignupService)
          whatsapp_channel = create(:channel_whatsapp, account: account, validate_provider_config: false, sync_templates: false)
          inbox = create(:inbox, account: account, channel: whatsapp_channel)

          allow(Whatsapp::EmbeddedSignupService).to receive(:new).and_return(embedded_signup_service)
          allow(embedded_signup_service).to receive(:perform).and_return(whatsapp_channel)
          allow(whatsapp_channel).to receive(:inbox).and_return(inbox)

          # Stub webhook setup service
          webhook_service = instance_double(Whatsapp::WebhookSetupService)
          allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
          allow(webhook_service).to receive(:perform)

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 code: 'test_code',
                 business_id: 'test_business_id',
                 waba_id: 'test_waba_id',
                 phone_number_id: 'test_phone_id'
               },
               headers: administrator.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
        end
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/whatsapp/authorization with inbox_id (reauthorization)' do
    let(:whatsapp_channel) do
      channel = build(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                                         provider_config: {
                                           'api_key' => 'test_token',
                                           'phone_number_id' => '123456',
                                           'business_account_id' => '654321',
                                           'source' => 'embedded_signup',
                                           'coexistence_sync' => {
                                             'state' => 'history_failed',
                                             'last_error' => 'Bearer test_token',
                                             'generation' => 'private-generation',
                                             'provider_payload' => { 'access_token' => 'nested-secret' }
                                           }
                                         })
      allow(channel).to receive(:validate_provider_config).and_return(true)
      allow(channel).to receive(:sync_templates).and_return(true)
      allow(channel).to receive(:setup_webhooks).and_return(true)
      allow(channel).to receive(:provider_authorization_healthy?).and_return(false)
      allow(channel).to receive(:provider_authorization_transient_failure?).and_return(false)
      channel.save!
      health_check = instance_double(Meta::AuthorizationHealthCheckService, healthy?: false)
      allow(Meta::AuthorizationHealthCheckService).to receive(:new).with(channel).and_return(health_check)
      # Call authorization_error! twice to reach the threshold
      channel.authorization_error!
      channel.authorization_error!
      channel
    end
    let(:whatsapp_inbox) { create(:inbox, channel: whatsapp_channel, account: account) }

    context 'when user is an administrator' do
      let(:administrator) { create(:user, account: account, role: :administrator) }

      context 'with valid parameters' do
        let(:valid_params) do
          {
            code: 'auth_code_123',
            business_id: 'business_123',
            waba_id: 'waba_123',
            phone_number_id: 'phone_123'
          }
        end

        it 'reauthorizes the WhatsApp channel successfully' do
          allow(whatsapp_channel).to receive(:reauthorization_required?).and_return(true)

          embedded_signup_service = instance_double(Whatsapp::EmbeddedSignupService)
          allow(Whatsapp::EmbeddedSignupService).to receive(:new).with(
            account: account,
            params: {
              code: 'auth_code_123',
              business_id: 'business_123',
              waba_id: 'waba_123',
              phone_number_id: 'phone_123'
            },
            inbox_id: whatsapp_inbox.id
          ).and_return(embedded_signup_service)
          allow(embedded_signup_service).to receive(:perform).and_return(whatsapp_channel)
          allow(whatsapp_channel).to receive(:inbox).and_return(whatsapp_inbox)

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: valid_params.merge(inbox_id: whatsapp_inbox.id),
               headers: administrator.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
          json_response = response.parsed_body
          expect(json_response['success']).to be true
          expect(json_response['id']).to eq(whatsapp_inbox.id)
          expect(json_response['provider_config']).to include(
            'phone_number_id' => '123456',
            'business_account_id' => '654321',
            'source' => 'embedded_signup'
          )
          expect(json_response.dig('provider_config', 'coexistence_sync')).to eq(
            'state' => 'history_failed', 'last_error' => 'Bearer [FILTERED]'
          )
          expect(json_response['provider_config']).not_to include('api_key')
          expect(json_response['provider_config'].to_json).not_to include(
            'test_token', 'private-generation', 'provider_payload', 'nested-secret'
          )
        end

        it 'handles reauthorization failure' do
          embedded_signup_service = instance_double(Whatsapp::EmbeddedSignupService)
          allow(Whatsapp::EmbeddedSignupService).to receive(:new).with(
            account: account,
            params: {
              code: 'auth_code_123',
              business_id: 'business_123',
              waba_id: 'waba_123',
              phone_number_id: 'phone_123'
            },
            inbox_id: whatsapp_inbox.id
          ).and_return(embedded_signup_service)
          allow(embedded_signup_service).to receive(:perform)
            .and_raise(StandardError, 'Token exchange failed')

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: valid_params.merge(inbox_id: whatsapp_inbox.id),
               headers: administrator.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          json_response = response.parsed_body
          expect(json_response['success']).to be false
          expect(json_response['error'])
            .to eq('WhatsApp authorization failed. Please check the connection details and try again.')
          expect(json_response['error_code']).to eq('authorization_failed')
        end

        it 'handles phone number mismatch error' do
          embedded_signup_service = instance_double(Whatsapp::EmbeddedSignupService)
          allow(Whatsapp::EmbeddedSignupService).to receive(:new).with(
            account: account,
            params: {
              code: 'auth_code_123',
              business_id: 'business_123',
              waba_id: 'waba_123',
              phone_number_id: 'phone_123'
            },
            inbox_id: whatsapp_inbox.id
          ).and_return(embedded_signup_service)
          allow(embedded_signup_service).to receive(:perform)
            .and_raise(Whatsapp::ReauthorizationService::PhoneNumberMismatchError,
                       'Phone number mismatch. The new phone number (+123****7890) does not match ' \
                       'the existing phone number (+155****4567). Please use the same WhatsApp ' \
                       'Business Account that was originally connected.')

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: valid_params.merge(inbox_id: whatsapp_inbox.id),
               headers: administrator.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          json_response = response.parsed_body
          expect(json_response['success']).to be false
          expect(json_response['error']).to include('Phone number mismatch')
          expect(json_response['error_code']).to eq('phone_number_mismatch')
        end
      end

      context 'when inbox does not exist' do
        it 'returns not found error' do
          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: { inbox_id: 0, code: 'test', business_id: 'test', waba_id: 'test' },
               headers: administrator.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:not_found)
        end
      end

      context 'when inbox belongs to another account' do
        it 'returns not found without invoking embedded signup' do
          foreign_inbox = create(:inbox, account: create(:account))

          expect(Whatsapp::EmbeddedSignupService).not_to receive(:new)

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 inbox_id: foreign_inbox.id,
                 code: 'test',
                 business_id: 'test',
                 waba_id: 'test',
                 phone_number_id: 'test'
               },
               headers: administrator.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:not_found)
        end
      end

      context 'when channel does not require reauthorization' do
        let(:fresh_channel) do
          channel = build(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                                             provider_config: {
                                               'api_key' => 'test_token',
                                               'phone_number_id' => '123456',
                                               'business_account_id' => '654321',
                                               'source' => 'embedded_signup'
                                             })
          allow(channel).to receive(:validate_provider_config).and_return(true)
          allow(channel).to receive(:sync_templates).and_return(true)
          allow(channel).to receive(:setup_webhooks).and_return(true)
          channel.save!
          # Do NOT call authorization_error! - channel is working fine
          channel
        end
        let(:fresh_inbox) { create(:inbox, channel: fresh_channel, account: account) }

        it 'returns unprocessable entity error' do
          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: { inbox_id: fresh_inbox.id },
               headers: administrator.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          json_response = response.parsed_body
          expect(json_response['success']).to be false
        end
      end

      context 'when token expires soon' do
        let(:expiring_channel) do
          channel = build(
            :channel_whatsapp,
            account: account,
            provider: 'whatsapp_cloud',
            provider_config: {
              'api_key' => 'test_token',
              'phone_number_id' => '123456',
              'business_account_id' => '654321',
              'source' => 'embedded_signup',
              'token_health' => { 'status' => 'expiring' }
            }
          )
          allow(channel).to receive(:validate_provider_config).and_return(true)
          allow(channel).to receive(:sync_templates).and_return(true)
          allow(channel).to receive(:setup_webhooks).and_return(true)
          channel.save!
          channel
        end
        let(:expiring_inbox) { create(:inbox, channel: expiring_channel, account: account) }

        it 'allows proactive reauthorization while the channel is still connected' do
          embedded_signup_service = instance_double(Whatsapp::EmbeddedSignupService, perform: expiring_channel)
          allow(Whatsapp::EmbeddedSignupService).to receive(:new).and_return(embedded_signup_service)
          allow(expiring_channel).to receive(:inbox).and_return(expiring_inbox)

          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: {
                 inbox_id: expiring_inbox.id,
                 code: 'test',
                 business_id: 'business_123',
                 waba_id: 'waba_123',
                 phone_number_id: 'phone_123'
               },
               headers: administrator.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
        end
      end

      context 'when channel is not WhatsApp' do
        let(:facebook_channel) do
          stub_request(:post, 'https://graph.facebook.com/v3.2/me/subscribed_apps')
            .to_return(status: 200, body: '{}', headers: {})

          channel = create(:channel_facebook_page, account: account)
          # Call authorization_error! twice to reach the threshold
          channel.authorization_error!
          channel.authorization_error!
          channel
        end
        let(:facebook_inbox) { create(:inbox, channel: facebook_channel, account: account) }

        it 'returns unprocessable entity error' do
          post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
               params: { inbox_id: facebook_inbox.id },
               headers: administrator.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          json_response = response.parsed_body
          expect(json_response['success']).to be false
        end
      end
    end

    context 'when user is an agent' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: whatsapp_inbox, user: agent)
      end

      it 'forbids proactive reauthorization of an expiring channel' do
        whatsapp_channel.reauthorized!
        whatsapp_channel.store_token_health!('status' => 'expiring')
        expect(Whatsapp::EmbeddedSignupService).not_to receive(:new)

        post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
             params: { inbox_id: whatsapp_inbox.id, code: 'test', business_id: 'test', waba_id: 'test', phone_number_id: 'phone' },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when user is not authenticated' do
      it 'returns unauthorized error' do
        post "/api/v1/accounts/#{account.id}/whatsapp/authorization",
             params: { inbox_id: whatsapp_inbox.id },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/whatsapp/authorization/session' do
    let(:administrator) { create(:user, account: account, role: :administrator) }

    it 'records a sanitized Embedded Signup session event' do
      allow(Rails.logger).to receive(:info)

      post "/api/v1/accounts/#{account.id}/whatsapp/authorization/session",
           params: { event: 'CANCEL', error_code: '123', session_id: 'session-1', access_token: 'secret' },
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:accepted)
      expect(Rails.logger).to have_received(:info).with(
        a_string_including(
          '"event":"whatsapp_embedded_signup_session"',
          '"event":"CANCEL"',
          '"session_id":"session-1"'
        )
      )
      expect(Rails.logger).not_to have_received(:info).with(a_string_including('secret'))
    end

    it 'forbids non-admin users from recording authorization sessions' do
      agent = create(:user, account: account, role: :agent)

      post "/api/v1/accounts/#{account.id}/whatsapp/authorization/session",
           params: { event: 'CANCEL' },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'requires authentication' do
      post "/api/v1/accounts/#{account.id}/whatsapp/authorization/session", params: { event: 'CANCEL' }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
