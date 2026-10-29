# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::KaspiPay::PaymentService do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account, phone_number: '+77012223344') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact).reload }
  let(:device) { Integrations::KaspiPay::Crypto.generate_device_identity }
  let!(:hook) do
    account.hooks.create!(
      app_id: 'kaspi_pay',
      hook_type: :account,
      status: :enabled,
      access_token: {
        'device' => device,
        'token_sn' => 'TSN_PAY_1',
        'vtoken_secret_b64' => Base64.strict_encode64('s' * 32)
      }.to_json,
      settings: { 'session_status' => 'active', 'profile_id' => '9911', 'organization_name' => 'Клиника МедЛайн' }
    )
  end

  let(:service) { described_class.new(account: account, actor: admin) }

  describe '#create_payment!' do
    it 'creates a QR + payment link, posts link to conversation when requested, and enqueues PollPaymentJob' do
      stub_request(:post, 'https://qrpay.kaspi.kz/v01/qr-token/create')
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: {
            StatusCode: 0,
            Data: {
              QrOperationId: '88776655',
              QrToken: 'https://qr.kaspi.kz/9988776655',
              ExpireDate: 15.minutes.from_now.iso8601,
              Amount: 12_500
            }
          }.to_json
        )

      payment = nil
      expect do
        payment = service.create_payment!(
          payment_type: 'qr', amount: 12_500, comment: 'Первичный приём',
          conversation_id: conversation.display_id, send_to_conversation: true
        )
      end.to have_enqueued_job(Integrations::KaspiPay::PollPaymentJob)

      expect(payment).to have_attributes(
        qr_operation_id: '88776655',
        unified_qr_url: 'https://qr.kaspi.kz/9988776655',
        pay_url: 'https://pay.kaspi.kz/pay/9988776655',
        status: 'pending'
      )
      expect(conversation.messages.outgoing.last.content).to include('https://pay.kaspi.kz/pay/9988776655')
    end

    it 'creates a remote Kaspi.kz invoice with normalized 10-digit phone and masked phone storage' do
      stub_request(:post, 'https://qrpay.kaspi.kz/v01/remote/create')
        .with { |req| JSON.parse(req.body)['PhoneNumber'] == '7012223344' && JSON.parse(req.body)['Amount'] == 8000 }
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { StatusCode: 0, Data: { QrOperationId: '44556677', Amount: 8000, OrderNumber: 'ORD-10' } }.to_json
        )

      payment = service.create_payment!(
        payment_type: 'invoice', amount: 8000, payer_phone: '+7 (701) 222-33-44',
        comment: 'Анализы', conversation_id: conversation.display_id
      )

      expect(payment).to have_attributes(payment_type: 'invoice', qr_operation_id: '44556677', payer_phone_masked: '+7 701 *** ** 44')
    end
  end

  describe 'appointment reconciliation and lifecycle' do
    let(:resource) do
      account.scheduling_resources.create!(name: 'Д-р Ахметов', specialty: 'Терапевт', timezone: 'Asia/Almaty', active: true)
    end
    let(:appointment) do
      account.scheduling_appointments.create!(
        resource: resource, contact: contact, conversation: conversation,
        client_name: 'Алия Серикова', starts_at: 1.day.from_now.change(hour: 10, min: 0),
        ends_at: 1.day.from_now.change(hour: 10, min: 30), source: 'manual',
        service_amount: 15_000, compensation_type_snapshot: 'percent',
        compensation_value_snapshot: 40, payment_status: 'awaiting_payment'
      )
    end

    it 'reconciles appointment payment_status & doctor expense on payment, and reverses on partial/full refund' do
      payment = account.kaspi_pay_payments.create!(
        hook: hook, contact: contact, conversation: conversation, appointment: appointment,
        created_by: admin, payment_type: 'qr', status: 'pending',
        qr_operation_id: 'OP_APPT_1', amount: 15_000, expires_at: 15.minutes.from_now
      )

      stub_request(:get, 'https://qrpay.kaspi.kz/v02/kaspi-qr/status?qrOperationId=OP_APPT_1')
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: { StatusCode: 0, Data: { Status: 'Processed', ReceiptUrl: 'https://kaspi.kz/r/1' } }.to_json)

      service.refresh_payment!(payment)
      expect(payment.reload.status).to eq('paid')
      expect(appointment.reload).to have_attributes(payment_status: 'paid')
      expect(appointment.expense&.amount).to eq(6000)

      stub_request(:post, 'https://qrpay.kaspi.kz/v01/kaspi-qr/history-pos-return')
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: { StatusCode: 0, Data: {} }.to_json)

      service.refund_payment!(payment, return_amount: 5000)
      expect(payment.reload).to have_attributes(status: 'partially_refunded', refundable_amount: 10_000)
      expect(appointment.reload.payment_status).to eq('prepaid')

      service.refund_payment!(payment)
      expect(payment.reload).to have_attributes(status: 'refunded', refundable_amount: 0)
      expect(appointment.reload.payment_status).to eq('awaiting_payment')
    end

    it 'cancels a pending remote invoice via /v01/remote/cancel' do
      payment = account.kaspi_pay_payments.create!(
        hook: hook, payment_type: 'invoice', status: 'pending', qr_operation_id: '900100', amount: 4000
      )

      stub_request(:post, 'https://qrpay.kaspi.kz/v01/remote/cancel')
        .with { |req| JSON.parse(req.body)['qrOperationId'] == 900_100 }
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: { StatusCode: 0, Data: {} }.to_json)

      service.cancel_payment!(payment)
      expect(payment.reload.status).to eq('cancelled')
    end

    it 'marks a QR payment as expired when Kaspi returns StatusCode -99000001 (Code 18, CodeSubsystem QR)' do
      payment = account.kaspi_pay_payments.create!(
        hook: hook, payment_type: 'qr', status: 'pending', qr_operation_id: '900200', amount: 7500, expires_at: 10.minutes.from_now
      )

      stub_request(:get, 'https://qrpay.kaspi.kz/v02/kaspi-qr/status?qrOperationId=900200')
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { StatusCode: -99_000_001, Code: 18, CodeSubsystem: 'QR', Message: 'Purchase not found' }.to_json
        )

      service.refresh_payment!(payment)
      expect(payment.reload.status).to eq('expired')
    end

    it 'settles a payment paid just before expires_at and allows manual recovery of an expired QR without double-crediting' do
      payment = account.kaspi_pay_payments.create!(
        hook: hook, contact: contact, conversation: conversation, appointment: appointment,
        created_by: admin, payment_type: 'qr', status: 'expired',
        qr_operation_id: 'OP_LATE_PAID', amount: 15_000, expires_at: 2.minutes.ago
      )

      stub_request(:get, 'https://qrpay.kaspi.kz/v02/kaspi-qr/status?qrOperationId=OP_LATE_PAID')
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { StatusCode: 0, Data: { Status: 'Processed', ReceiptUrl: 'https://kaspi.kz/r/late' } }.to_json
        )

      service.refresh_payment!(payment)
      service.refresh_payment!(payment)
      expect(payment.reload.status).to eq('paid')
      expect(appointment.reload).to have_attributes(payment_status: 'paid', settlement_amount: 15_000)
      expect(appointment.payments.where(payment_method: 'kaspi_pay').count).to eq(1)
    end

    it 'forbids local cancellation of QR payments and prevents concurrent double refunds via Redis lock' do
      qr_payment = account.kaspi_pay_payments.create!(
        hook: hook, payment_type: 'qr', status: 'pending', qr_operation_id: 'QR_NO_CANCEL', amount: 3000
      )
      expect { service.cancel_payment!(qr_payment) }.to raise_error(described_class::PaymentError, /удалённых счетов/)

      paid_payment = account.kaspi_pay_payments.create!(
        hook: hook, payment_type: 'qr', status: 'paid', qr_operation_id: 'QR_LOCK_TEST', amount: 10_000
      )
      lock_key = "kaspi_pay:refund_lock:#{paid_payment.id}"
      Redis::Alfred.set(lock_key, 'other-worker', nx: true, ex: 30)
      expect { service.refund_payment!(paid_payment, return_amount: 5000) }
        .to raise_error(described_class::PaymentError, /уже выполняется/)
    ensure
      Redis::Alfred.delete(lock_key) if lock_key
    end
  end
end
