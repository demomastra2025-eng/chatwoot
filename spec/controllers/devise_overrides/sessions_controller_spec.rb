require 'rails_helper'

RSpec.describe DeviseOverrides::SessionsController, type: :controller do
  include Devise::Test::ControllerHelpers

  before do
    request.env['devise.mapping'] = Devise.mappings[:user]
  end

  describe 'POST #create' do
    let(:user) { create(:user, password: 'Test@123456') }

    context 'with standard authentication' do
      it 'authenticates with valid credentials' do
        post :create, params: { email: user.email, password: 'Test@123456' }

        expect(response).to have_http_status(:success)
      end

      it 'activates the current auth client for the user' do
        post :create, params: { email: user.email, password: 'Test@123456' }

        expect(user.reload.active_auth_client_id).to eq(response.headers['client'])
        expect(user.reload.active_auth_client_set_at).to be_present
      end

      it 'broadcasts session replacement to the previously active client in the same device type' do
        request.headers['HTTP_USER_AGENT'] = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)'
        post :create, params: { email: user.email, password: 'Test@123456' }
        previous_client_id = response.headers['client']

        expect(ActionCable.server).to receive(:broadcast).with(
          user.auth_session_stream_name(previous_client_id),
          hash_including(event: 'auth.session_replaced')
        )

        request.headers['HTTP_USER_AGENT'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        post :create, params: { email: user.email, password: 'Test@123456' }

        expect(user.reload.active_auth_client_id).to eq(response.headers['client'])
      end

      it 'keeps desktop and mobile web sessions active at the same time' do
        request.headers['HTTP_USER_AGENT'] = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)'
        post :create, params: { email: user.email, password: 'Test@123456' }
        desktop_client_id = response.headers['client']

        expect(ActionCable.server).not_to receive(:broadcast).with(
          user.auth_session_stream_name(desktop_client_id),
          anything
        )

        request.headers['HTTP_USER_AGENT'] = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Mobile/15E148'
        post :create, params: { email: user.email, password: 'Test@123456' }
        mobile_client_id = response.headers['client']

        expect(user.reload).to be_active_auth_client(desktop_client_id)
        expect(user).to be_active_auth_client(mobile_client_id)
      end

      it 'rejects invalid credentials' do
        post :create, params: { email: user.email, password: 'wrong' }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with MFA authentication' do
      before do
        skip('Skipping since MFA is not configured in this environment') unless Chatwoot.encryption_configured?
        user.enable_two_factor!
        user.update!(otp_required_for_login: true)
      end

      it 'requires MFA verification after successful password authentication' do
        post :create, params: { email: user.email, password: 'Test@123456' }

        expect(response).to have_http_status(:partial_content)
        json_response = response.parsed_body
        expect(json_response['mfa_required']).to be(true)
        expect(json_response['mfa_token']).to be_present
      end

      it 'does not return authentication tokens before MFA verification' do
        post :create, params: { email: user.email, password: 'Test@123456' }

        expect(response).to have_http_status(:partial_content)

        # Check that no authentication headers are present
        expect(response.headers['access-token']).to be_nil
        expect(response.headers['uid']).to be_nil
        expect(response.headers['client']).to be_nil
        expect(response.headers['Authorization']).to be_nil

        # Check that no bearer token is present in any form
        response.headers.each do |key, value|
          expect(value.to_s).not_to include('Bearer') if key.downcase.include?('auth')
        end

        json_response = response.parsed_body
        expect(json_response['data']).to be_nil
      end

      context 'when verifying MFA' do
        let(:mfa_token) { Mfa::TokenService.new(user: user).generate_token }

        it 'authenticates with valid OTP' do
          post :create, params: {
            mfa_token: mfa_token,
            otp_code: user.current_otp
          }

          expect(response).to have_http_status(:success)
        end

        it 'authenticates with valid backup code' do
          backup_codes = user.generate_backup_codes!

          post :create, params: {
            mfa_token: mfa_token,
            backup_code: backup_codes.first
          }

          expect(response).to have_http_status(:success)
        end

        it 'rejects invalid OTP' do
          post :create, params: {
            mfa_token: mfa_token,
            otp_code: '000000'
          }

          expect(response).to have_http_status(:bad_request)
          expect(response.parsed_body['error']).to eq(I18n.t('errors.mfa.invalid_code'))
        end

        it 'rejects invalid backup code' do
          user.generate_backup_codes!

          post :create, params: {
            mfa_token: mfa_token,
            backup_code: 'invalid'
          }

          expect(response).to have_http_status(:bad_request)
          expect(response.parsed_body['error']).to eq(I18n.t('errors.mfa.invalid_code'))
        end

        it 'rejects expired MFA token' do
          expired_token = JWT.encode(
            { user_id: user.id, exp: 1.minute.ago.to_i },
            Rails.application.secret_key_base,
            'HS256'
          )

          post :create, params: {
            mfa_token: expired_token,
            otp_code: user.current_otp
          }

          expect(response).to have_http_status(:unauthorized)
          expect(response.parsed_body['error']).to eq(I18n.t('errors.mfa.invalid_token'))
        end

        it 'requires either OTP or backup code' do
          post :create, params: { mfa_token: mfa_token }

          expect(response).to have_http_status(:bad_request)
          expect(response.parsed_body['error']).to eq(I18n.t('errors.mfa.invalid_code'))
        end
      end
    end

    context 'with SSO authentication' do
      it 'authenticates with valid SSO token' do
        sso_token = user.generate_sso_auth_token

        post :create, params: {
          email: user.email,
          sso_auth_token: sso_token
        }

        expect(response).to have_http_status(:success)
      end

      it 'rejects invalid SSO token' do
        post :create, params: {
          email: user.email,
          sso_auth_token: 'invalid'
        }

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'GET #new' do
    it 'redirects to frontend login page' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('FRONTEND_URL', nil).and_return('/frontend')

      get :new

      expect(response).to redirect_to('/frontend/app/login?error=access-denied')
    end
  end
end
