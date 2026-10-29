# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Integrations::KaspiPay', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  describe 'GET /api/v1/accounts/:account_id/integrations/kaspi_pay/status' do
    it 'forbids non-admin agents and returns status without exposing secrets to admins' do
      get "/api/v1/accounts/#{account.id}/integrations/kaspi_pay/status",
          headers: agent.create_new_auth_token,
          as: :json
      expect(response).to have_http_status(:unauthorized)

      device = Integrations::KaspiPay::Crypto.generate_device_identity
      account.hooks.create!(
        app_id: 'kaspi_pay',
        hook_type: :account,
        status: :enabled,
        access_token: {
          'device' => device,
          'token_sn' => 'SECRET_TOKEN_SN',
          'vtoken_secret_b64' => Base64.strict_encode64('k' * 32)
        }.to_json,
        settings: {
          'organization_name' => 'ТОО Клиника Алматы',
          'organization_bin' => '190140011223',
          'cashier_phone_masked' => '+7 701 *** ** 11'
        }
      )

      get "/api/v1/accounts/#{account.id}/integrations/kaspi_pay/status",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['connected']).to be(true)
      expect(body['organization_name']).to eq('ТОО Клиника Алматы')
      expect(response.body).not_to include('SECRET_TOKEN_SN')
      expect(response.body).not_to include('ec_private_key')
    end
  end

  describe 'DELETE /api/v1/accounts/:account_id/integrations/kaspi_pay/disconnect' do
    it 'destroys the Kaspi Pay hook for the account' do
      device = Integrations::KaspiPay::Crypto.generate_device_identity
      account.hooks.create!(
        app_id: 'kaspi_pay',
        hook_type: :account,
        status: :enabled,
        access_token: { 'device' => device, 'token_sn' => 'T1', 'vtoken_secret_b64' => Base64.strict_encode64('z' * 32) }.to_json
      )

      delete "/api/v1/accounts/#{account.id}/integrations/kaspi_pay/disconnect",
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['connected']).to be(false)
      expect(account.hooks.where(app_id: 'kaspi_pay')).to be_empty
    end
  end
end
