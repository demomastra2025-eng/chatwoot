# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::KaspiPay::Payments', type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:allowed_inbox) { create(:inbox, account: account) }
  let(:restricted_inbox) { create(:inbox, account: account) }
  let(:allowed_conv) { create(:conversation, account: account, inbox: allowed_inbox).reload }
  let(:restricted_conv) { create(:conversation, account: account, inbox: restricted_inbox).reload }
  let(:device) { Integrations::KaspiPay::Crypto.generate_device_identity }
  let!(:hook) do
    account.hooks.create!(
      app_id: 'kaspi_pay',
      hook_type: :account,
      status: :enabled,
      access_token: {
        'device' => device,
        'token_sn' => 'TSN_REQ_1',
        'vtoken_secret_b64' => Base64.strict_encode64('p' * 32)
      }.to_json,
      settings: { 'session_status' => 'active', 'profile_id' => '111' }
    )
  end

  before do
    create(:inbox_member, user: agent, inbox: allowed_inbox)
    restricted_inbox.inbox_members.where(user: agent).delete_all
  end

  describe 'POST /api/v1/accounts/:account_id/kaspi_pay/payments' do
    before do
      stub_request(:post, 'https://qrpay.kaspi.kz/v01/qr-token/create')
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: {
            StatusCode: 0,
            Data: { QrOperationId: '551122', QrToken: 'https://qr.kaspi.kz/551122', Amount: 6000 }
          }.to_json
        )
    end

    it 'allows an agent with inbox access to create a QR payment and serializes conversation display_id' do
      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments",
           params: { payment_type: 'qr', amount: 6000, conversation_id: allowed_conv.display_id },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body['pay_url']).to eq('https://pay.kaspi.kz/pay/551122')
      expect(response.parsed_body['conversation_id']).to eq(allowed_conv.display_id)
    end

    it 'blocks cross-entity binding when a restricted agent passes another patient contact_id' do
      other_contact = create(:contact, account: account, phone_number: '+77018889900')
      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments",
           params: {
             payment_type: 'qr', amount: 6000,
             conversation_id: allowed_conv.display_id, contact_id: other_contact.id
           },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('Контакт не совпадает')
    end

    it 'blocks an agent without inbox access from creating a payment in a restricted conversation' do
      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments",
           params: { payment_type: 'qr', amount: 6000, conversation_id: restricted_conv.display_id },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'blocks a non-admin agent from creating an unlinked account-level payment without conversation_id' do
      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments",
           params: { payment_type: 'qr', amount: 6000 },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'POST /api/v1/accounts/:account_id/kaspi_pay/payments/:id/refund and tenant isolation' do
    let!(:payment) do
      account.kaspi_pay_payments.create!(
        hook: hook, conversation: allowed_conv, payment_type: 'qr',
        status: 'paid', qr_operation_id: '777888', amount: 9000
      )
    end
    let!(:other_payment) do
      other_account.kaspi_pay_payments.create!(
        payment_type: 'qr', status: 'paid', qr_operation_id: '999000', amount: 5000
      )
    end

    it 'forbids non-admin agents from issuing refunds' do
      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments/#{payment.id}/refund",
           params: { amount: 9000 }, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'enforces strict account isolation (returns 404 for another account payment)' do
      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments/#{other_payment.id}/refund",
           params: { amount: 5000 }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'allows an administrator to refund a paid payment' do
      stub_request(:post, 'https://qrpay.kaspi.kz/v01/kaspi-qr/history-pos-return')
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: { StatusCode: 0, Data: {} }.to_json)

      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments/#{payment.id}/refund",
           params: { amount: 9000 }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['status']).to eq('refunded')
    end

    it 'hides conversation payments from an agent whose inbox access was later revoked' do
      revoked_payment = account.kaspi_pay_payments.create!(
        hook: hook, conversation: restricted_conv, created_by: agent,
        payment_type: 'qr', status: 'pending', qr_operation_id: 'REVOKED_OP_1', amount: 4500
      )

      get "/api/v1/accounts/#{account.id}/kaspi_pay/payments", headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
      ids = response.parsed_body['payload'].map { |item| item['id'] }
      expect(ids).not_to include(revoked_payment.id)
    end

    it 'returns masked phone and client_name without raw provider payload in POST client_info' do
      stub_request(:get, 'https://qrpay.kaspi.kz/v01/remote/client-info?phoneNumber=7012223344')
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { StatusCode: 0, Data: { ClientName: 'Асет К.', PhoneNumber: '7012223344' } }.to_json
        )

      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments/client_info",
           params: { phone_number: '+7 701 222 33 44', conversation_id: allowed_conv.display_id },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('phone_masked' => '+7 701 *** ** 44', 'client_name' => 'Асет К.')
    end
  end
end
