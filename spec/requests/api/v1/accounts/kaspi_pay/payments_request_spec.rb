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
        qr_token: 'https://pay.kaspi.kz/pay/token',
        qr_original_token: 'https://qr.kaspi.kz/original-token'
      )
      allow(KaspiPay::PaymentCreator).to receive(:new).with(
        hook: hook,
        source: appointment,
        amount: 15_000,
        idempotency_key: 'idem-1',
        payment_type: 'qr',
        phone_number: nil,
        comment: nil
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
        'qr_original_token' => 'https://qr.kaspi.kz/original-token',
        'kaspi_operation_id' => 'qr-1'
      )
    end

    it 'can attach a QR payment to a conversation when created from the reply box display id' do
      conversation = create(:conversation, account: account)
      creator = instance_double(KaspiPay::PaymentCreator)
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook, source: conversation, amount: 15_000)
      allow(KaspiPay::PaymentCreator).to receive(:new).with(
        hook: hook,
        source: conversation,
        amount: 15_000,
        idempotency_key: a_string_matching(/^kaspi-pay:conversation:#{conversation.display_id}:15000:qr:/),
        payment_type: 'qr',
        phone_number: nil,
        comment: nil
      ).and_return(creator)
      allow(creator).to receive(:create_qr!).and_return(payment)

      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments",
           params: {
             conversation_id: conversation.display_id,
             amount: 15_000,
             idempotency_key: "kaspi-pay:conversation:#{conversation.display_id}:15000:qr:browser"
           },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to include('id' => payment.id, 'amount' => 15_000, 'source_type' => 'Conversation', 'source_id' => conversation.id)
    end

    it 'creates a remote invoice payment when requested' do
      conversation = create(:conversation, account: account)
      creator = instance_double(KaspiPay::PaymentCreator)
      payment = create(
        :kaspi_pay_payment,
        account: account,
        integration_hook: hook,
        source: conversation,
        payment_type: 'invoice',
        amount: 15_000,
        kaspi_operation_id: 'remote-1',
        kaspi_order_number: 'order-1'
      )
      allow(KaspiPay::PaymentCreator).to receive(:new).with(
        hook: hook,
        source: conversation,
        amount: 15_000,
        idempotency_key: a_string_matching(/^kaspi-pay:conversation:#{conversation.id}:15000:invoice:/),
        payment_type: 'invoice',
        phone_number: '77011234567',
        comment: 'Order 1'
      ).and_return(creator)
      allow(creator).to receive(:create_invoice!).and_return(payment)

      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments",
           params: { conversation_id: conversation.id, amount: 15_000, payment_type: 'invoice', phone_number: '77011234567', comment: 'Order 1' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to include('payment_type' => 'invoice', 'kaspi_operation_id' => 'remote-1', 'kaspi_order_number' => 'order-1')
    end

    it 'rejects unsupported payment_type before creating or calling Kaspi' do
      hook
      allow(KaspiPay::PaymentCreator).to receive(:new)

      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments",
           params: { conversation_id: create(:conversation, account: account).id, amount: 15_000, payment_type: 'wire' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'INVALID_PAYMENT_TYPE')
      expect(KaspiPay::PaymentCreator).not_to have_received(:new)
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
        payment_type: 'qr',
        phone_number: nil,
        comment: nil
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

  describe 'POST /api/v1/accounts/:account_id/kaspi_pay/payments/:id/cancel' do
    it 'cancels an account-scoped invoice' do
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook, source: appointment, payment_type: 'invoice',
                                           kaspi_operation_id: 'invoice-1')
      service = instance_double(KaspiPay::InvoiceCancellationService)
      allow(KaspiPay::InvoiceCancellationService).to receive(:new).with(payment: payment).and_return(service)
      allow(service).to receive(:cancel!) do
        payment.update!(status: 'cancelled', failed_at: Time.current)
        payment
      end

      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments/#{payment.id}/cancel",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('id' => payment.id, 'status' => 'cancelled')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/kaspi_pay/payments/history' do
    it 'returns provider history through an account-scoped hook' do
      history = instance_double(KaspiPay::HistoryService)
      allow(KaspiPay::HistoryService).to receive(:new).with(hook: hook).and_return(history)
      allow(history).to receive(:operations).with(
        end_date: '2026-07-17', last_transaction_date: nil, statement_period_code: 0
      ).and_return('Operations' => [{ 'Id' => 1 }])

      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments/history",
           params: { end_date: '2026-07-17' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('Operations' => [{ 'Id' => 1 }])
    end
  end

  describe 'POST /api/v1/accounts/:account_id/kaspi_pay/payments/:id/refund' do
    it 'requests a refund for an account-scoped Kaspi payment' do
      payment = create(:kaspi_pay_payment, account: account, integration_hook: hook, source: appointment, amount: 15_000, status: 'paid',
                                           kaspi_operation_id: '15530881826')
      service = instance_double(KaspiPay::RefundService)
      allow(KaspiPay::RefundService).to receive(:new).with(payment: payment, return_amount: 15_000).and_return(service)
      allow(service).to receive(:refund!) do
        payment.update!(status: 'refunded', failed_at: Time.current, metadata: { 'refund_amount' => 15_000 })
        payment
      end

      post "/api/v1/accounts/#{account.id}/kaspi_pay/payments/#{payment.id}/refund",
           params: { amount: 15_000 },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('id' => payment.id, 'status' => 'refunded', 'refund_amount' => 15_000)
    end
  end
end
