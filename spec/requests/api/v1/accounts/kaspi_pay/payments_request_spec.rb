require 'rails_helper'

RSpec.describe 'Kaspi Pay payments API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:hook) { create(:integrations_hook, :kaspi_pay, account: account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:service) { create(:scheduling_service, account: account) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: service, service_amount: 15_000)
  end

  describe 'POST /api/v1/accounts/:account_id/kaspi_pay/payments' do
    it 'requires authentication' do
      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments", as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not create a payment when this account has no enabled Kaspi Pay hook' do
      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments",
           params: { amount: 15_000, conversation_id: create(:conversation, account: account).id },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:not_found)
      expect(KaspiPay::Payment.where(account: account)).to be_empty
    end

    it 'creates a QR payment via the account Kaspi Pay hook' do
      creator = instance_double(KaspiPay::PaymentCreator)
      payment = create(
        :kaspi_pay_payment,
        account: account,
        integration_hook: hook,
        source: appointment,
        amount: 15_000,
        kaspi_operation_id: 'qr-1',
        qr_token: 'https://pay.kaspi.kz/pay/token'
      )
      allow(KaspiPay::PaymentCreator).to receive(:new).with(
        hook: hook,
        source: appointment,
        amount: 15_000,
        idempotency_key: 'idem-1',
        payment_type: 'qr'
      ).and_return(creator)
      allow(creator).to receive(:create_qr!).and_return(payment)

      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments",
           params: { appointment_id: appointment.id, amount: 15_000, idempotency_key: 'idem-1' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to include(
        'id' => payment.id,
        'status' => 'pending',
        'qr_token' => 'https://pay.kaspi.kz/pay/token',
        'kaspi_operation_id' => 'qr-1'
      )
    end

    it 'can attach a QR payment to a conversation when created from the reply box' do
      conversation = create(:conversation, account: account)
      creator = instance_double(KaspiPay::PaymentCreator)
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook, source: conversation, amount: 15_000)
      allow(KaspiPay::PaymentCreator).to receive(:new).with(
        hook: hook,
        source: conversation,
        amount: 15_000,
        idempotency_key: a_string_matching(/^kaspi-pay:conversation:#{conversation.id}:15000:qr:/),
        payment_type: 'qr'
      ).and_return(creator)
      allow(creator).to receive(:create_qr!).and_return(payment)

      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments",
           params: { conversation_id: conversation.id, amount: 15_000 },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to include('id' => payment.id, 'amount' => 15_000)
    end

    it 'uses the appointment remaining amount when amount is omitted' do
      appointment.update!(prepaid_amount: 2_000, prepaid_payment_method: 'cash')
      creator = instance_double(KaspiPay::PaymentCreator)
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook, source: appointment, amount: 13_000)
      allow(KaspiPay::PaymentCreator).to receive(:new).with(
        hook: hook,
        source: appointment,
        amount: 13_000,
        idempotency_key: "kaspi-pay:appointment:#{appointment.id}:13000:qr",
        payment_type: 'qr'
      ).and_return(creator)
      allow(creator).to receive(:create_qr!).and_return(payment)

      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments",
           params: { appointment_id: appointment.id },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to include('id' => payment.id, 'amount' => 13_000)
    end

    it 'rejects payment creation without a positive amount' do
      hook

      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments",
           params: { conversation_id: create(:conversation, account: account).id },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'INVALID_AMOUNT')
    end
  end

  describe 'GET /api/v1/accounts/:account_id/kaspi_pay/payments/:id' do
    it 'returns only account-scoped payment payload' do
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook, source: appointment, amount: 15_000)

      get "/api/v1/accounts/#{account.id}/kaspi_pay/payments/#{payment.id}",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include('id' => payment.id, 'amount' => 15_000, 'status' => 'pending')
    end
  end
end
