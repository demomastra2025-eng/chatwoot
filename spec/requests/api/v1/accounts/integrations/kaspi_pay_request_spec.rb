require 'rails_helper'

RSpec.describe 'Kaspi Pay integration API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:auth_service) { instance_double(KaspiPay::AuthService) }

  describe 'POST /api/v1/accounts/:account_id/integrations/kaspi_pay/auth/init' do
    it 'requires authentication' do
      post "/api/v1/accounts/#{account.id}/integrations/kaspi_pay/auth/init", as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns the provider process id' do
      allow(KaspiPay::AuthService).to receive(:new).with(account: account).and_return(auth_service)
      allow(auth_service).to receive(:init).and_return({ process_id: 'process-1', view: 'EnterPhoneNumber' })

      post "/api/v1/accounts/#{account.id}/integrations/kaspi_pay/auth/init",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include('process_id' => 'process-1', 'view' => 'EnterPhoneNumber')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/integrations/kaspi_pay/auth/verify_otp' do
    it 'creates a Kaspi Pay hook with server-side session secrets' do
      allow(KaspiPay::AuthService).to receive(:new).with(account: account).and_return(auth_service)
      allow(auth_service).to receive(:verify_otp).and_return(
        {
          token_sn: 'token-sn',
          vtoken_secret: 'encrypted-secret',
          profile_id: 'profile-1',
          organization_id: 'org-1',
          org_name: 'Merchant',
          phone_number: '77001234567'
        }
      )
      allow(auth_service).to receive(:connect!) do |session:, settings:|
        account.hooks.create!(
          app_id: 'kaspi_pay',
          settings: settings,
          access_token: session.to_json
        )
      end

      post "/api/v1/accounts/#{account.id}/integrations/kaspi_pay/auth/verify_otp",
           params: {
             process_id: 'process-1',
             otp: '1234',
             phone_number: '77001234567',
             settings: { default_payment_type: 'qr', latitude: 43.238949, longitude: 76.889709 }
           },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      hook = account.hooks.find_by!(app_id: 'kaspi_pay')
      expect(hook.secret_settings).to include('token_sn' => 'token-sn', 'vtoken_secret' => 'encrypted-secret')
      expect(response.parsed_body['secret_settings']).to be_nil
      expect(response.parsed_body['metadata']).to include('org_name' => 'Merchant', 'phone_number' => '77001234567')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/integrations/kaspi_pay/auth/refresh' do
    it 'refreshes the existing Kaspi Pay session without exposing secrets' do
      hook = create(:integrations_hook, :kaspi_pay, account: account)
      allow(KaspiPay::AuthService).to receive(:new).with(account: account).and_return(auth_service)
      allow(auth_service).to receive(:refresh!).with(hook: hook).and_return(hook)

      post "/api/v1/accounts/#{account.id}/integrations/kaspi_pay/auth/refresh",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['secret_settings']).to be_nil
      expect(response.parsed_body['metadata']).to include('profile_id' => hook.secret_settings['profile_id'])
    end
  end

  describe 'DELETE /api/v1/accounts/:account_id/integrations/kaspi_pay' do
    it 'disables the hook and clears secrets without deleting payment history' do
      hook = create(:integrations_hook, :kaspi_pay, account: account)
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook)

      delete "/api/v1/accounts/#{account.id}/integrations/kaspi_pay",
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:ok)
      expect(hook.reload).to be_disabled
      expect(hook.access_token).to be_blank
      expect(account.kaspi_pay_payments.find(payment.id)).to eq(payment)
    end
  end
end
